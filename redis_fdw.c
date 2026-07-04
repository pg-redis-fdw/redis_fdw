/*-------------------------------------------------------------------------
 *
 *		  foreign-data wrapper for Redis
 *
 * Copyright (c) 2011 - 2025, PostgreSQL Global Development Group
 *
 * This software is released under the PostgreSQL Licence
 *
 * Authors: Dave Page <dpage@pgadmin.org>
 *			Andrew Dunstan <andrew@dunslane.net>
 *
 * IDENTIFICATION
 *		  redis_fdw/redis_fdw.c
 *
 *-------------------------------------------------------------------------
 */

/* Debug mode */
/* #define DEBUG */

#include "postgres.h"
#include <hiredis/hiredis.h>

/* check that we are compiling for the right postgres version */
#if PG_VERSION_NUM < 140000
#error Selected Postgresql version is very old for this branch, try to use some older branch.
#endif

#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>


#include "funcapi.h"
#include "access/reloptions.h"
#include "access/sysattr.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_foreign_server.h"
#include "catalog/pg_foreign_table.h"
#include "catalog/pg_user_mapping.h"
#include "catalog/pg_type.h"
#include "commands/defrem.h"
#if PG_VERSION_NUM >= 180000
#include "commands/explain_format.h"
#include "commands/explain_state.h"
#else
#include "commands/explain.h"
#endif
#include "foreign/fdwapi.h"
#include "foreign/foreign.h"
#include "miscadmin.h"
#include "mb/pg_wchar.h"
#include "nodes/pathnodes.h"
#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "optimizer/appendinfo.h"
#if PG_VERSION_NUM >= 160000
#include "optimizer/inherit.h"
#endif
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/planmain.h"
#include "optimizer/restrictinfo.h"
#include "parser/parsetree.h"
#include "storage/fd.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/syscache.h"
#include "storage/ipc.h"

PG_MODULE_MAGIC;

/*
 * Code version is updated at new release.
 * The last two digits are the minor version, whilst the leading digits should
 * match the SQL API major version, e.g. 2 for 2.x.
 */
#define REDIS_FDW_CODE_VERSION  201

#define PROCID_TEXTEQ 67

/*
 * Describes the valid options for objects that use this wrapper.
 */
struct RedisFdwOption
{
	const char *optname;
	Oid			optcontext;		/* Oid of catalog in which option may appear */
};

/*
 * Valid options for redis_fdw.
 *
 */
static struct RedisFdwOption valid_options[] =
{
	/* Connection options */
	{"address", ForeignServerRelationId},
	{"port", ForeignServerRelationId},
	{"password", UserMappingRelationId},

	/* table options */
	{"database", ForeignTableRelationId},
	{"singleton_key", ForeignTableRelationId},
	{"tablekeyprefix", ForeignTableRelationId},
	{"tablekeyset", ForeignTableRelationId},
	{"tabletype", ForeignTableRelationId},

	/* Sentinel */
	{NULL, InvalidOid}
};

typedef enum
{
	PG_REDIS_SCALAR_TABLE = 0,
	PG_REDIS_HASH_TABLE,
	PG_REDIS_LIST_TABLE,
	PG_REDIS_SET_TABLE,
	PG_REDIS_ZSET_TABLE
} redis_table_type;

typedef struct redisTableOptions
{
	char	   *address;
	int			port;
	char	   *password;
	int			database;
	char	   *keyprefix;
	char	   *keyset;
	char	   *singleton_key;
	redis_table_type table_type;
} redisTableOptions;

typedef struct
{
	char	   *svr_address;
	int			svr_port;
	char	   *svr_password;
	int			svr_database;
} RedisFdwPlanState;

/*
 * FDW-specific information for ForeignScanState.fdw_state.
 */

typedef struct RedisFdwExecutionState
{
	AttInMetadata *attinmeta;
	redisContext *context;

	/*
	 * reply is what the scan iterates over; owned_reply is what has to be
	 * handed back to hiredis. They are the same object for a singleton key,
	 * but a cursor scan replies with [cursor, [keys...]] and only the second
	 * element is iterated, so reply points into owned_reply there. Always
	 * free owned_reply - freeing reply would ask hiredis to release a subtree
	 * its parent still points at, and would leak the parent.
	 */
	redisReply *reply;
	redisReply *owned_reply;
	long long	row;
	char	   *address;
	int			port;
	char	   *password;
	int			database;
	char	   *keyprefix;
	char	   *keyset;
	char	   *qual_value;
	char	   *singleton_key;
	redis_table_type table_type;
	char	   *cursor_search_string;
	char	   *cursor_id;
	MemoryContext mctxt;
} RedisFdwExecutionState;

typedef struct RedisFdwModifyState
{
	redisContext *context;
	char	   *address;
	int			port;
	char	   *password;
	int			database;
	char	   *keyprefix;
	char	   *keyset;
	char	   *qual_value;
	char	   *singleton_key;
	Relation	rel;
	redis_table_type table_type;
	List	   *target_attrs;
	int		   *targetDims;
	int			p_nums;
	int			keyAttno;
	Oid			array_elem_type;
	FmgrInfo   *p_flinfo;
} RedisFdwModifyState;

/* initial cursor */
#define ZERO "0"
/* redis default is 10 - let's fetch 1000 at a time */
#define COUNT " COUNT 1000"

/*
 * Connection cache structures
 */
#define REDIS_CONN_CACHE_SIZE 32

typedef struct RedisConnCacheKey
{
	char		address[256];
	int			port;
	char		password[256];
	int			database;
} RedisConnCacheKey;

typedef struct RedisConnCacheEntry
{
	RedisConnCacheKey key;		/* Must be first for hash lookup */
	redisContext *context;
	bool		used_in_xact;	/* checked out in the current transaction */
	bool		invalidated;	/* discard at end of transaction */
} RedisConnCacheEntry;

/* Connection cache - shared within backend */
static HTAB *RedisConnCache = NULL;
static bool RedisConnCacheInitialized = false;

/*
 * Connections discarded because their socket failed. Freeing one at the point
 * of discard would leave a concurrent holder with a dangling pointer -- two
 * scans in one query can share a cache entry -- so the redisFree is deferred
 * to end of transaction, by which time no executor state holds a reference.
 */
static List *RedisDeadContexts = NIL;

/*
 * SQL functions
 */
extern Datum redis_fdw_handler(PG_FUNCTION_ARGS);
extern Datum redis_fdw_validator(PG_FUNCTION_ARGS);
extern Datum redis_fdw_version(PG_FUNCTION_ARGS);
extern Datum redis_fdw_hiredis_version(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(redis_fdw_handler);
PG_FUNCTION_INFO_V1(redis_fdw_validator);
PG_FUNCTION_INFO_V1(redis_fdw_version);
PG_FUNCTION_INFO_V1(redis_fdw_hiredis_version);

/*
 * FDW callback routines
 */
static void redisGetForeignRelSize(PlannerInfo *root,
					   RelOptInfo *baserel,
					   Oid foreigntableid);
static void redisGetForeignPaths(PlannerInfo *root,
					 RelOptInfo *baserel,
					 Oid foreigntableid);
static ForeignScan *redisGetForeignPlan(PlannerInfo *root,
					RelOptInfo *baserel,
					Oid foreigntableid,
					ForeignPath *best_path,
					List *tlist,
					List *scan_clauses,
					Plan *outer_plan);

static void redisExplainForeignScan(ForeignScanState *node, ExplainState *es);
static void redisBeginForeignScan(ForeignScanState *node, int eflags);
static TupleTableSlot *redisIterateForeignScan(ForeignScanState *node);
static inline TupleTableSlot *redisIterateForeignScanMulti(ForeignScanState *node);
static inline TupleTableSlot *redisIterateForeignScanSingleton(ForeignScanState *node);
static void redisReScanForeignScan(ForeignScanState *node);
static void redisEndForeignScan(ForeignScanState *node);


static List *redisPlanForeignModify(PlannerInfo *root,
					   ModifyTable *plan,
					   Index resultRelation,
					   int subplan_index);

static void redisBeginForeignModify(ModifyTableState *mtstate,
						ResultRelInfo *rinfo,
						List *fdw_private,
						int subplan_index,
						int eflags);

static TupleTableSlot *redisExecForeignInsert(EState *estate,
					   ResultRelInfo *rinfo,
					   TupleTableSlot *slot,
					   TupleTableSlot *planSlot);

static void redisEndForeignModify(EState *estate,
								  ResultRelInfo *rinfo);

static void redisAddForeignUpdateTargets(PlannerInfo *root,
										 Index rtindex,
										 RangeTblEntry *target_rte,
										 Relation target_relation);

static TupleTableSlot *redisExecForeignDelete(EState *estate,
					   ResultRelInfo *rinfo,
					   TupleTableSlot *slot,
					   TupleTableSlot *planSlot);

static TupleTableSlot *redisExecForeignUpdate(EState *estate,
					   ResultRelInfo *rinfo,
					   TupleTableSlot *slot,
					   TupleTableSlot *planSlot);

/*
 * Helper functions
 */
static bool redisIsValidOption(const char *option, Oid context);
static void redisGetOptions(Oid foreigntableid, redisTableOptions *options);
static void redisGetQual(Node *node, TupleDesc tupdesc, char **key,
						 char **value, bool *pushdown);
static char *redis_escape_glob(const char *str);

/*
 * Allowed-reply-type mask for check_reply. Every caller states the type(s)
 * the command it issued is contracted to return, so that a reply which is
 * well-formed but of the wrong shape is rejected before anything indexes
 * into it. RTYPE_ANY is for genuinely unconstrained replies - not for
 * "we don't read this one yet", since the reply a caller ignores today is
 * the one it dereferences tomorrow.
 */
#define RTYPE(t)	(1 << (t))
#define RTYPE_ANY	0

static char *redis_array_to_text(redisReply *reply);
static void check_reply(redisReply *reply, redisContext *context,
						int allowed, int error_code, char *message, char *arg);
static redisReply *redis_command_impl(redisContext *context,
						const char *cmd, size_t cmd_len,
						const char *key, size_t key_len,
						const char *extra_arg, size_t extra_len,
						const char *data, size_t data_len);

/* Connection cache functions */
static void redis_conn_cache_init(void);
static void redis_conn_cache_cleanup(int code, Datum arg);
static void redis_conn_cache_invalidate_callback(Datum arg, int cacheid, uint32 hashvalue);
static void redis_build_cache_key(RedisConnCacheKey *key, redisTableOptions *options);
static bool redis_validate_connection(redisContext *context);
static redisContext *redis_get_connection(redisTableOptions *options);
static RedisConnCacheEntry *redis_find_cache_entry(redisContext *context);
static void redis_discard_connection(redisContext *context);
static void redis_conn_cache_end_xact(void);
static void redis_xact_callback(XactEvent event, void *arg);

/*
 * Name we will use for the junk attribute that holds the redis key
 * for update and delete operations.
 */
#define REDISMODKEYNAME "__redis_mod_key_name"

/*
 * redis_fdw_handler
 *		Foreign-data wrapper handler function: return a struct with pointers
 *		to my callback routines.
 */
Datum
redis_fdw_handler(PG_FUNCTION_ARGS)
{
	FdwRoutine *fdwroutine = makeNode(FdwRoutine);

#ifdef DEBUG
	elog(NOTICE, "redis_fdw_handler");
#endif

	fdwroutine->GetForeignRelSize = redisGetForeignRelSize;
	fdwroutine->GetForeignPaths = redisGetForeignPaths;
	fdwroutine->GetForeignPlan = redisGetForeignPlan;
	/* can't ANALYSE redis */
	fdwroutine->AnalyzeForeignTable = NULL;
	fdwroutine->ExplainForeignScan = redisExplainForeignScan;
	fdwroutine->BeginForeignScan = redisBeginForeignScan;
	fdwroutine->IterateForeignScan = redisIterateForeignScan;
	fdwroutine->ReScanForeignScan = redisReScanForeignScan;
	fdwroutine->EndForeignScan = redisEndForeignScan;

	fdwroutine->PlanForeignModify = redisPlanForeignModify;		/* I U D */
	fdwroutine->BeginForeignModify = redisBeginForeignModify;	/* I U D */
	fdwroutine->ExecForeignInsert = redisExecForeignInsert;		/* I */
	fdwroutine->EndForeignModify = redisEndForeignModify;		/* I U D */

	fdwroutine->ExecForeignUpdate = redisExecForeignUpdate;		/* U */
	fdwroutine->ExecForeignDelete = redisExecForeignDelete;		/* D */
	fdwroutine->AddForeignUpdateTargets = redisAddForeignUpdateTargets; /* U D */

	PG_RETURN_POINTER(fdwroutine);
}

/*
 * redis_conn_cache_init
 *		Initialize the connection cache hash table.
 */
static void
redis_conn_cache_init(void)
{
	HASHCTL		hash_ctl;

	if (RedisConnCacheInitialized)
		return;

	memset(&hash_ctl, 0, sizeof(hash_ctl));
	hash_ctl.keysize = sizeof(RedisConnCacheKey);
	hash_ctl.entrysize = sizeof(RedisConnCacheEntry);
	hash_ctl.hcxt = CacheMemoryContext;

	RedisConnCache = hash_create("redis_fdw connection cache",
								 REDIS_CONN_CACHE_SIZE,
								 &hash_ctl,
								 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	on_proc_exit(redis_conn_cache_cleanup, 0);

	RedisConnCacheInitialized = true;
}

/*
 * redis_conn_cache_cleanup
 *		Clean up all cached connections on backend exit.
 */
static void
redis_conn_cache_cleanup(int code, Datum arg)
{
	ListCell   *lc;

	if (RedisConnCacheInitialized && RedisConnCache)
	{
		HASH_SEQ_STATUS scan;
		RedisConnCacheEntry *entry;

		hash_seq_init(&scan, RedisConnCache);
		while ((entry = hash_seq_search(&scan)) != NULL)
		{
			if (entry->context)
			{
				redisFree(entry->context);
				entry->context = NULL;
			}
		}
	}

	foreach(lc, RedisDeadContexts)
		redisFree((redisContext *) lfirst(lc));

	RedisDeadContexts = NIL;
}

/*
 * redis_conn_cache_invalidate_callback
 *		Syscache callback for FOREIGNSERVEROID/USERMAPPINGOID.
 *
 *		This is not what makes an option change take effect. The cache is
 *		keyed by the connection option values themselves, so an ALTER SERVER
 *		or ALTER USER MAPPING that changes any of them produces a different
 *		key: the next lookup misses and connects to the new target whether
 *		or not this callback ran. Correctness does not depend on it.
 *
 *		What it does is reclaim the superseded entry. Without it the old key
 *		keeps its context - and its socket - for the life of the backend,
 *		because nothing will ever look that key up again. Marking every
 *		entry invalidated is blunt, and it fires for changes to any foreign
 *		server or user mapping in the database, including those belonging to
 *		other FDWs; that is acceptable only because this cache is
 *		per-backend, small, and cheap to repopulate.
 *
 *		An entry in use in the current transaction is not disturbed here -
 *		redis_conn_cache_end_xact() drops it at end of transaction.
 */
static void
redis_conn_cache_invalidate_callback(Datum arg, int cacheid, uint32 hashvalue)
{
	HASH_SEQ_STATUS scan;
	RedisConnCacheEntry *entry;

	if (!RedisConnCacheInitialized || !RedisConnCache)
		return;

	hash_seq_init(&scan, RedisConnCache);
	while ((entry = hash_seq_search(&scan)) != NULL)
		entry->invalidated = true;
}

/*
 * redis_conn_cache_end_xact
 *		End-of-transaction cleanup for the connection cache.
 *
 *		Cached connections are held for the duration of a transaction, so this
 *		is where they are released: clear the per-transaction mark on every
 *		entry, drop any entry a syscache invalidation marked stale, and free
 *		the contexts discarded during the transaction.
 *
 *		Entries are left in the hash with a NULL context rather than removed,
 *		as postgres_fdw does; the key is small and will very likely be reused.
 */
static void
redis_conn_cache_end_xact(void)
{
	ListCell   *lc;

	if (RedisConnCacheInitialized && RedisConnCache)
	{
		HASH_SEQ_STATUS scan;
		RedisConnCacheEntry *entry;

		hash_seq_init(&scan, RedisConnCache);
		while ((entry = hash_seq_search(&scan)) != NULL)
		{
			entry->used_in_xact = false;

			if (entry->invalidated && entry->context)
			{
				redisFree(entry->context);
				entry->context = NULL;
				entry->invalidated = false;
			}
		}
	}

	foreach(lc, RedisDeadContexts)
		redisFree((redisContext *) lfirst(lc));

	list_free(RedisDeadContexts);
	RedisDeadContexts = NIL;
}

/*
 * redis_xact_callback
 *		Transaction callback: the executor End nodes do not run when a
 *		statement aborts, so end of transaction is the only point at which
 *		connection cleanup is guaranteed to happen on both the success and the
 *		failure path. This mirrors postgres_fdw's pgfdw_xact_callback.
 *
 *		No subtransaction callback is needed: nothing is released at
 *		subtransaction boundaries, so a subtransaction abort has nothing to
 *		reconcile.
 */
static void
redis_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_ABORT:
		case XACT_EVENT_PREPARE:
		case XACT_EVENT_PARALLEL_COMMIT:
		case XACT_EVENT_PARALLEL_ABORT:
			redis_conn_cache_end_xact();
			break;
		default:
			break;
	}
}

/*
 * _PG_init
 *		Module load callback: register for invalidation of cached
 *		connections when a foreign server or user mapping changes.
 */
void
_PG_init(void)
{
	CacheRegisterSyscacheCallback(FOREIGNSERVEROID,
								   redis_conn_cache_invalidate_callback,
								   (Datum) 0);
	CacheRegisterSyscacheCallback(USERMAPPINGOID,
								   redis_conn_cache_invalidate_callback,
								   (Datum) 0);

	RegisterXactCallback(redis_xact_callback, NULL);
}

/*
 * redis_build_cache_key
 *		Build a cache key from connection options.
 */
static void
redis_build_cache_key(RedisConnCacheKey *key, redisTableOptions *options)
{
	memset(key, 0, sizeof(RedisConnCacheKey));

	if (options->address)
		strlcpy(key->address, options->address, sizeof(key->address));
	else
		strlcpy(key->address, "127.0.0.1", sizeof(key->address));

	key->port = options->port ? options->port : 6379;

	if (options->password)
		strlcpy(key->password, options->password, sizeof(key->password));

	key->database = options->database;
}

/*
 * redis_validate_connection
 *		Check if a cached connection is still alive using PING.
 */
static bool
redis_validate_connection(redisContext *context)
{
	redisReply *reply;
	bool		valid = false;

	if (!context)
		return false;

	reply = redisCommand(context, "PING");

	if (reply && reply->type == REDIS_REPLY_STATUS &&
		strcmp(reply->str, "PONG") == 0)
	{
		valid = true;
	}

	if (reply)
		freeReplyObject(reply);

	return valid;
}

/*
 * redis_get_connection
 *		Get a connection from cache or create a new one.
 *		The connection is held until end of transaction and released by
 *		redis_conn_cache_end_xact; callers must not free or release it.
 */
static redisContext *
redis_get_connection(redisTableOptions *options)
{
	RedisConnCacheKey key;
	RedisConnCacheEntry *entry;
	bool		found;
	redisContext *context;
	redisReply *reply;
	struct timeval timeout = {1, 500000};

	redis_conn_cache_init();

	redis_build_cache_key(&key, options);

	entry = hash_search(RedisConnCache, &key, HASH_ENTER, &found);

	if (found && entry->context)
	{
		/*
		 * A connection is held for the whole transaction, so it only needs
		 * validating on its first checkout in each one.
		 *
		 * This deliberately tests used_in_xact before invalidated: an entry
		 * can only be both at once when a syscache invalidation marked it
		 * while the socket still works, and in that case the teardown belongs
		 * at end of transaction rather than in the middle of a statement. The
		 * I/O-failure path clears used_in_xact, so it never reaches here.
		 */
		if (entry->used_in_xact)
			return entry->context;

		if (!entry->invalidated && redis_validate_connection(entry->context))
		{
			entry->used_in_xact = true;
			return entry->context;
		}

		redis_discard_connection(entry->context);
	}

	context = redisConnectWithTimeout(
		options->address ? options->address : "127.0.0.1",
		options->port ? options->port : 6379,
		timeout);

	if (context->err)
	{
		char	   *errstr = pstrdup(context->errstr);

		redisFree(context);
		hash_search(RedisConnCache, &key, HASH_REMOVE, NULL);
		ereport(ERROR,
				(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
				 errmsg("failed to connect to Redis: %s", errstr)));
	}

	if (options->password)
	{
		reply = redisCommand(context, "AUTH %s", options->password);

		if (!reply)
		{
			char	   *err = pstrdup(context->errstr);

			redisFree(context);
			hash_search(RedisConnCache, &key, HASH_REMOVE, NULL);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
					 errmsg("failed to authenticate to Redis: %s", err)));
		}

		if (reply->type == REDIS_REPLY_ERROR)
		{
			char	   *err = pstrdup(reply->str);

			freeReplyObject(reply);
			redisFree(context);
			hash_search(RedisConnCache, &key, HASH_REMOVE, NULL);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
					 errmsg("failed to authenticate to Redis: %s", err)));
		}

		freeReplyObject(reply);
	}

	reply = redisCommand(context, "SELECT %d", options->database);

	if (!reply)
	{
		char	   *err = pstrdup(context->errstr);

		redisFree(context);
		hash_search(RedisConnCache, &key, HASH_REMOVE, NULL);
		ereport(ERROR,
				(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
				 errmsg("failed to select database %d: %s",
						options->database, err)));
	}

	if (reply->type == REDIS_REPLY_ERROR)
	{
		char	   *err = pstrdup(reply->str);

		freeReplyObject(reply);
		redisFree(context);
		hash_search(RedisConnCache, &key, HASH_REMOVE, NULL);
		ereport(ERROR,
				(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
				 errmsg("failed to select database %d: %s",
						options->database, err)));
	}

	freeReplyObject(reply);

	entry->context = context;
	entry->used_in_xact = true;
	entry->invalidated = false;

	return context;
}

/*
 * redis_find_cache_entry
 *		Find the cache entry currently holding the given connection, if any.
 */
static RedisConnCacheEntry *
redis_find_cache_entry(redisContext *context)
{
	HASH_SEQ_STATUS scan;
	RedisConnCacheEntry *entry;

	if (!context || !RedisConnCacheInitialized || !RedisConnCache)
		return NULL;

	hash_seq_init(&scan, RedisConnCache);
	while ((entry = hash_seq_search(&scan)) != NULL)
	{
		if (entry->context == context)
		{
			hash_seq_term(&scan);
			return entry;
		}
	}

	return NULL;
}

/*
 * redis_discard_connection
 *		Drop a connection whose socket has failed, so that the next checkout
 *		reconnects.
 *
 *		The context is not freed here. A concurrent holder may still point at
 *		it -- two scans in one query can share a cache entry -- so the free is
 *		deferred to end of transaction, where nothing holds a reference. A
 *		stale holder is left pointing at valid memory backing a dead socket,
 *		so it gets an error rather than a crash. The deferral also covers
 *		this function's own callers: several of them read context->err or
 *		context->errstr for an error message immediately after calling this,
 *		which is only safe because the context they are still holding has not
 *		actually been freed yet.
 *
 *		Unlike postgres_fdw, this reconnects mid-transaction rather than
 *		poisoning the connection until the transaction ends. postgres_fdw must
 *		refuse, because reconnecting would abandon an open remote transaction
 *		and its uncommitted writes; Redis has no transaction to abandon, and
 *		refusing would strand the user partway through writes that have
 *		already been applied and that no rollback will undo.
 */
static void
redis_discard_connection(redisContext *context)
{
	RedisConnCacheEntry *entry = redis_find_cache_entry(context);
	MemoryContext oldcxt;

	if (!entry || !entry->context)
		return;

	oldcxt = MemoryContextSwitchTo(CacheMemoryContext);
	RedisDeadContexts = lappend(RedisDeadContexts, entry->context);
	MemoryContextSwitchTo(oldcxt);

	entry->context = NULL;
	entry->invalidated = false;
	entry->used_in_xact = false;
}

/*
 * redis_fdw_validator
 *		Validate the generic options given to a FOREIGN DATA WRAPPER, SERVER,
 *		USER MAPPING or FOREIGN TABLE that uses file_fdw.
 *
 *		Raise an ERROR if the option or its value is considered invalid.
 */
Datum
redis_fdw_validator(PG_FUNCTION_ARGS)
{
	List	   *options_list = untransformRelOptions(PG_GETARG_DATUM(0));
	Oid			catalog = PG_GETARG_OID(1);
	char	   *svr_address = NULL;
	int			svr_port = 0;
	char	   *svr_password = NULL;
	int			svr_database = 0;
	redis_table_type tabletype = PG_REDIS_SCALAR_TABLE;
	char	   *tablekeyprefix = NULL;
	char	   *tablekeyset = NULL;
	char	   *singletonkey = NULL;
	ListCell   *cell;

#ifdef DEBUG
	elog(NOTICE, "redis_fdw_validator");
#endif

	/*
	 * Check that only options supported by redis_fdw, and allowed for the
	 * current object type, are given.
	 */
	foreach(cell, options_list)
	{
		DefElem    *def = (DefElem *) lfirst(cell);

		if (!redisIsValidOption(def->defname, catalog))
		{
			struct RedisFdwOption *opt;
			StringInfoData buf;

			/*
			 * Unknown option specified, complain about it. Provide a hint
			 * with list of valid options for the object.
			 */
			initStringInfo(&buf);
			for (opt = valid_options; opt->optname; opt++)
			{
				if (catalog == opt->optcontext)
					appendStringInfo(&buf, "%s%s", (buf.len > 0) ? ", " : "",
									 opt->optname);
			}

			ereport(ERROR,
					(errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
					 errmsg("invalid option \"%s\"", def->defname),
					 errhint("Valid options in this context are: %s",
							 buf.len ? buf.data : "<none>")
					 ));
		}

		if (strcmp(def->defname, "address") == 0)
		{
			if (svr_address)
				ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR),
								errmsg("conflicting or redundant options: "
									   "address (%s)", defGetString(def))
								));

			svr_address = defGetString(def);
		}
		else if (strcmp(def->defname, "port") == 0)
		{
			if (svr_port)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: port (%s)",
								defGetString(def))
						 ));

			svr_port = atoi(defGetString(def));
		}
		if (strcmp(def->defname, "password") == 0)
		{
			if (svr_password)
				ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: password")
								));

			svr_password = defGetString(def);
		}
		else if (strcmp(def->defname, "database") == 0)
		{
			if (svr_database)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: database "
								"(%s)", defGetString(def))
						 ));

			svr_database = atoi(defGetString(def));
		}
		else if (strcmp(def->defname, "singleton_key ") == 0)
		{
			if (tablekeyset)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting options: tablekeyset(%s) and "
								"singleton_key (%s)", tablekeyset,
								defGetString(def))
						 ));
			if (tablekeyprefix)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting options: tablekeyprefix(%s) and "
								"singleton_key (%s)", tablekeyprefix,
								defGetString(def))
						 ));
			if (singletonkey)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: "
								"singleton_key (%s)", defGetString(def))
						 ));

			singletonkey = defGetString(def);
		}
		else if (strcmp(def->defname, "tablekeyprefix") == 0)
		{
			if (tablekeyset)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting options: tablekeyset(%s) and "
								"tablekeyprefix (%s)", tablekeyset,
								defGetString(def))
						 ));
			if (singletonkey)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting options: singleton_key(%s) and "
								"tablekeyprefix (%s)", singletonkey,
								defGetString(def))
						 ));
			if (tablekeyprefix)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: "
								"tablekeyprefix (%s)", defGetString(def))
						 ));

			tablekeyprefix = defGetString(def);
		}
		else if (strcmp(def->defname, "tablekeyset") == 0)
		{
			if (tablekeyprefix)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
					   errmsg("conflicting options: tablekeyprefix (%s) and "
							  "tablekeyset (%s)", tablekeyprefix,
							  defGetString(def))
						 ));
			if (singletonkey)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting options: singleton_key(%s) and "
								"tablekeyset (%s)", singletonkey,
								defGetString(def))
						 ));
			if (tablekeyset)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: "
								"tablekeyset (%s)", defGetString(def))
						 ));

			tablekeyset = defGetString(def);
		}
		else if (strcmp(def->defname, "tabletype") == 0)
		{
			char	   *typeval = defGetString(def);

			if (tabletype)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("conflicting or redundant options: tabletype "
								"(%s)", typeval)));
			if (strcmp(typeval, "hash") == 0)
				tabletype = PG_REDIS_HASH_TABLE;
			else if (strcmp(typeval, "list") == 0)
				tabletype = PG_REDIS_LIST_TABLE;
			else if (strcmp(typeval, "set") == 0)
				tabletype = PG_REDIS_SET_TABLE;
			else if (strcmp(typeval, "zset") == 0)
				tabletype = PG_REDIS_ZSET_TABLE;
			else
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("invalid tabletype (%s) - must be hash, "
								"list, set or zset", typeval)));
		}
	}

	PG_RETURN_VOID();
}

/*
 * redisIsValidOption
 *		Check if the provided option is one of the valid options.
 *		context is the Oid of the catalog holding the object the option is for.
 */
static bool
redisIsValidOption(const char *option, Oid context)
{
	struct RedisFdwOption *opt;

#ifdef DEBUG
	elog(NOTICE, "redisIsValidOption");
#endif

	for (opt = valid_options; opt->optname; opt++)
	{
		if (context == opt->optcontext && strcmp(opt->optname, option) == 0)
			return true;
	}
	return false;
}

/*
 * redisGetOptions
 *		Fetch the options for a redis_fdw foreign table.
 */
static void
redisGetOptions(Oid foreigntableid, redisTableOptions *table_options)
{
	ForeignTable *table;
	ForeignServer *server;
	UserMapping *mapping;
	List	   *options;
	ListCell   *lc;

#ifdef DEBUG
	elog(NOTICE, "redisGetOptions");
#endif

	/* Set void values */
	table_options->address = NULL;
	table_options->port = 0;
	table_options->password = NULL;
	table_options->database = 0;
	table_options->keyprefix = NULL;
	table_options->keyset = NULL;
	table_options->singleton_key = NULL;
	table_options->table_type = PG_REDIS_SCALAR_TABLE;

	/*
	 * Extract options from FDW objects. We only need to worry about server
	 * options for Redis
	 */
	table = GetForeignTable(foreigntableid);
	server = GetForeignServer(table->serverid);
	mapping = GetUserMapping(GetUserId(), table->serverid);

	options = NIL;
	options = list_concat(options, table->options);
	options = list_concat(options, server->options);
	options = list_concat(options, mapping->options);

	/* Loop through the options, and get the server/port */
	foreach(lc, options)
	{
		DefElem    *def = (DefElem *) lfirst(lc);

		if (strcmp(def->defname, "address") == 0)
			table_options->address = defGetString(def);

		if (strcmp(def->defname, "port") == 0)
			table_options->port = atoi(defGetString(def));

		if (strcmp(def->defname, "password") == 0)
			table_options->password = defGetString(def);

		if (strcmp(def->defname, "database") == 0)
			table_options->database = atoi(defGetString(def));

		if (strcmp(def->defname, "tablekeyprefix") == 0)
			table_options->keyprefix = defGetString(def);

		if (strcmp(def->defname, "tablekeyset") == 0)
			table_options->keyset = defGetString(def);

		if (strcmp(def->defname, "singleton_key") == 0)
			table_options->singleton_key = defGetString(def);

		if (strcmp(def->defname, "tabletype") == 0)
		{
			char	   *typeval = defGetString(def);

			if (strcmp(typeval, "hash") == 0)
				table_options->table_type = PG_REDIS_HASH_TABLE;
			else if (strcmp(typeval, "list") == 0)
				table_options->table_type = PG_REDIS_LIST_TABLE;
			else if (strcmp(typeval, "set") == 0)
				table_options->table_type = PG_REDIS_SET_TABLE;
			else if (strcmp(typeval, "zset") == 0)
				table_options->table_type = PG_REDIS_ZSET_TABLE;
			else
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("invalid tabletype (%s) - must be hash, "
								"list, set or zset", typeval)));
		}
	}

	/* Default values, if required */
	if (!table_options->address)
		table_options->address = "127.0.0.1";

	if (!table_options->port)
		table_options->port = 6379;

	if (!table_options->database)
		table_options->database = 0;
}

/*
 * redisGetForeignRelSize
 *		Gets size of a foreign realtion as value from
 *		HLEN, LLEN, SCARD, ZCARD or DBSIZE Redis command
 *		returns baserel->rows
 */
/*
 * redis_escape_glob
 *		Escape the Redis pattern metacharacters in a literal string, so that
 *		it matches only itself when embedded in a KEYS or SCAN MATCH pattern.
 *
 *		Redis's matcher treats '*', '?' and '[' specially and uses '\' as its
 *		escape character, so each of those has to be backslash-escaped. A
 *		tablekeyprefix is a literal prefix rather than a pattern, so it must
 *		be escaped before the trailing '*' is appended to it.
 */
static char *
redis_escape_glob(const char *str)
{
	size_t		len = strlen(str);
	char	   *result = palloc(len * 2 + 1);
	char	   *dst = result;

	while (*str)
	{
		if (*str == '*' || *str == '?' || *str == '[' || *str == '\\')
			*dst++ = '\\';
		*dst++ = *str++;
	}
	*dst = '\0';

	return result;
}

static void
redisGetForeignRelSize(PlannerInfo *root,
					   RelOptInfo *baserel,
					   Oid foreigntableid)
{
	RedisFdwPlanState *fdw_private;
	redisTableOptions table_options;

	redisContext *context;
	redisReply *reply = NULL;

#ifdef DEBUG
	elog(NOTICE, "redisGetForeignRelSize");
#endif

	/*
	 * Fetch options. Get everything so we don't need to re-fetch it later in
	 * planning.
	 */
	fdw_private = (RedisFdwPlanState *) palloc(sizeof(RedisFdwPlanState));
	baserel->fdw_private = (void *) fdw_private;

	redisGetOptions(foreigntableid, &table_options);
	fdw_private->svr_address = table_options.address;
	fdw_private->svr_password = table_options.password;
	fdw_private->svr_port = table_options.port;
	fdw_private->svr_database = table_options.database;

	/* Connect to the database (via connection cache) */
	context = redis_get_connection(&table_options);

	/* Execute a query to get the table size */
#if 0

	/*
	 * KEYS is potentially expensive, so this test is disabled and we use a
	 * fairly dubious heuristic instead.
	 */
	if (table_options.keyprefix)
	{
		/* it's a pity there isn't an NKEYS command in Redis */
		char	   *escaped = redis_escape_glob(table_options.keyprefix);
		int			len = strlen(escaped) + 2;
		char	   *buff = palloc(len * sizeof(char));

		snprintf(buff, len, "%s*", escaped);
		reply = redisCommand(context, "KEYS %s", buff);
	}
	else
#endif
	if (table_options.singleton_key)
	{
		switch (table_options.table_type)
		{
			case PG_REDIS_SCALAR_TABLE:
				baserel->rows = 1;
				return;
			case PG_REDIS_HASH_TABLE:
				reply = redisCommand(context, "HLEN %s", table_options.singleton_key);
				break;
			case PG_REDIS_LIST_TABLE:
				reply = redisCommand(context, "LLEN %s", table_options.singleton_key);
				break;
			case PG_REDIS_SET_TABLE:
				reply = redisCommand(context, "SCARD %s", table_options.singleton_key);
				break;
			case PG_REDIS_ZSET_TABLE:
				reply = redisCommand(context, "ZCARD %s", table_options.singleton_key);
				break;
			default:
				;
		}
	}
	else if (table_options.keyset)
	{
		reply = redisCommand(context, "SCARD %s", table_options.keyset);
	}
	else
	{
		reply = redisCommand(context, "DBSIZE");
	}

	check_reply(reply, context, RTYPE(REDIS_REPLY_INTEGER),
				ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
				"failed to get the database size", NULL);

	if (table_options.keyprefix)
		baserel->rows = reply->integer / 20;
	else
		baserel->rows = reply->integer;

	freeReplyObject(reply);
}

/*
 * redisGetForeignPaths
 *		Create possible access paths for a scan on the foreign table
 *
 *		Currently we don't support any push-down feature, so there is only one
 *		possible access path, which simply returns all records in redis.
 */
static void
redisGetForeignPaths(PlannerInfo *root,
					 RelOptInfo *baserel,
					 Oid foreigntableid)
{
	RedisFdwPlanState *fdw_private = baserel->fdw_private;

	Cost		startup_cost,
				total_cost;

#ifdef DEBUG
	elog(NOTICE, "redisGetForeignPaths");
#endif

	if (strcmp(fdw_private->svr_address, "127.0.0.1") == 0 ||
		strcmp(fdw_private->svr_address, "localhost") == 0)
		startup_cost = 10;
	else
		startup_cost = 25;

	total_cost = startup_cost + baserel->rows;


	/* Create a ForeignPath node and add it as only possible path */
	add_path(baserel, (Path *)
			 create_foreignscan_path(root, baserel,
									 NULL,      /* default pathtarget */
									 baserel->rows,
#if PG_VERSION_NUM >= 180000
									 0,         /* no disabled nodes */
#endif
									 startup_cost,
									 total_cost,
									 NIL,		/* no pathkeys */
									 NULL,		/* no outer rel either */
									 NULL,      /* no extra plan */
#if PG_VERSION_NUM >= 170000
									 NIL,       /* no fdw_restrictinfo list */
#endif
									 NIL));		/* no fdw_private data */
}

/*
 * redisGetForeignPlan
 *		Create ForeignScan plan node which implements only possible execution
 *		"path" for Redis
 */
static ForeignScan *
redisGetForeignPlan(PlannerInfo *root,
					RelOptInfo *baserel,
					Oid foreigntableid,
					ForeignPath *best_path,
					List *tlist,
					List *scan_clauses,
					Plan *outer_plan)
{
	Index		scan_relid = baserel->relid;

#ifdef DEBUG
	elog(NOTICE, "redisGetForeignPlan");
#endif

	/*
	 * We have no native ability to evaluate restriction clauses, so we just
	 * put all the scan_clauses into the plan node's qual list for the
	 * executor to check.  So all we have to do here is strip RestrictInfo
	 * nodes from the clauses and ignore pseudoconstants (which will be
	 * handled elsewhere).
	 */
	scan_clauses = extract_actual_clauses(scan_clauses, false);

	/* Create the ForeignScan node */
	return make_foreignscan(tlist,
							scan_clauses,
							scan_relid,
							NIL,	/* no expressions to evaluate */
							NIL,	/* no private state either */
							NIL,    /* no custom tlist */
							NIL,    /* no remote quals */
							outer_plan);
}

/*
 * fileExplainForeignScan
 *		Produce extra output for EXPLAIN
 */
static void
redisExplainForeignScan(ForeignScanState *node, ExplainState *es)
{
	redisReply *reply;

	RedisFdwExecutionState *festate = (RedisFdwExecutionState *) node->fdw_state;

#ifdef DEBUG
	elog(NOTICE, "redisExplainForeignScan");
#endif

	if (!es->costs)
		return;

	/*
	 * Execute a query to get the table size
	 *
	 * See above for more details.
	 */

	if (festate->keyset)
	{
		reply = redisCommand(festate->context, "SCARD %s", festate->keyset);
	}
	else
	{
		reply = redisCommand(festate->context, "DBSIZE");
	}

	check_reply(reply, festate->context, RTYPE(REDIS_REPLY_INTEGER),
				ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION,
				"failed to get the table size", NULL);

	ExplainPropertyInteger("Foreign Redis Table Size", "b",
						festate->keyprefix ? reply->integer / 20 :
						reply->integer,
						es);

	freeReplyObject(reply);
}

/*
 * redisBeginForeignScan
 *		Initiate access to the database
 */
static void
redisBeginForeignScan(ForeignScanState *node, int eflags)
{
	redisTableOptions table_options;
	redisContext *context;
	redisReply *reply = NULL;
	char	   *qual_key = NULL;
	char	   *qual_value = NULL;
	bool		pushdown = false;
	RedisFdwExecutionState *festate;

#ifdef DEBUG
	elog(NOTICE, "BeginForeignScan");
#endif

	/* Fetch options  */
	redisGetOptions(RelationGetRelid(node->ss.ss_currentRelation),
					&table_options);

	/* Connect to the server (via connection cache) */
	context = redis_get_connection(&table_options);

	/* See if we've got a qual we can push down */
	if (node->ss.ps.plan->qual)
	{
		ListCell   *lc;

		foreach(lc, node->ss.ps.plan->qual)
		{
			/* Only the first qual can be pushed down to Redis */
			Expr  *state = lfirst(lc);

			redisGetQual((Node *) state,
						 node->ss.ss_currentRelation->rd_att,
						 &qual_key, &qual_value, &pushdown);
			if (pushdown)
				break;
		}
	}

	/* Stash away the state info we have already */
	festate = (RedisFdwExecutionState *) palloc(sizeof(RedisFdwExecutionState));
	node->fdw_state = (void *) festate;
	festate->context = context;
	festate->reply = NULL;
	festate->owned_reply = NULL;
	festate->row = 0;
	festate->address = table_options.address;
	festate->port = table_options.port;
	festate->keyprefix = table_options.keyprefix;
	festate->keyset = table_options.keyset;
	festate->singleton_key = table_options.singleton_key;
	festate->table_type = table_options.table_type;
	festate->cursor_id = NULL;
	festate->cursor_search_string = NULL;

	festate->qual_value = pushdown ? qual_value : NULL;

	/* OK, we connected. If this is an EXPLAIN, bail out now */
	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	/*
	 * We're going to use the current scan-lived context to
	 * store the pstrduped cusrsor id.
	 */
	festate->mctxt = CurrentMemoryContext;

	/* Execute the query */
	reply = NULL;

	if (festate->singleton_key)
	{
		/*
		 * We're not using cursors for now for singleton key tables. The
		 * theory is that we don't expect them to be so large in normal use
		 * that we would get any significant benefit from doing so, and in any
		 * case scanning them in a single step is not going to tie things up
		 * like scannoing the whole Redis database could.
		 */

		switch (table_options.table_type)
		{
			case PG_REDIS_SCALAR_TABLE:
				reply = redisCommand(context, "GET %s", festate->singleton_key);
				break;
			case PG_REDIS_HASH_TABLE:
				/* the singleton case where a qual pushdown makes most sense */
				if (qual_value && pushdown)
					reply = redisCommand(context, "HGET %s %s", festate->singleton_key, qual_value);
				else
					reply = redisCommand(context, "HGETALL %s", festate->singleton_key);
				break;
			case PG_REDIS_LIST_TABLE:
				reply = redisCommand(context, "LRANGE %s 0 -1", table_options.singleton_key);
				break;
			case PG_REDIS_SET_TABLE:
				reply = redisCommand(context, "SMEMBERS %s", table_options.singleton_key);
				break;
			case PG_REDIS_ZSET_TABLE:
				reply = redisCommand(context, "ZRANGEBYSCORE %s -inf inf WITHSCORES", table_options.singleton_key);
				break;
			default:
				;
		}
	}
	else if (qual_value && pushdown)
	{
		/*
		 * if we have a qual, make sure it's a member of the keyset or has the
		 * right prefix if either of these options is specified.
		 *
		 * If not set row to -1 to indicate failure
		 */
		if (festate->keyset)
		{
			redisReply *sreply;

			sreply = redisCommand(context, "SISMEMBER %s %s",
								  festate->keyset, qual_value);
			check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER),
						ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
						"failed to list keys", NULL);

			if (sreply->integer != 1)
				festate->row = -1;

			freeReplyObject(sreply);
		}
		else if (festate->keyprefix)
		{
			if (strncmp(qual_value, festate->keyprefix,
						strlen(festate->keyprefix)) != 0)
				festate->row = -1;
		}

		/*
		 * For a qual we don't want to scan at all, just check that the key
		 * exists. We do this check in adddition to the keyset/keyprefix
		 * checks, is any, so we know the item is really there.
		 */

		reply = redisCommand(context, "EXISTS %s", qual_value);
		check_reply(reply, context, RTYPE(REDIS_REPLY_INTEGER),
					ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
					"failed to check key existence for %s", qual_value);
		if (reply->integer == 0)
			festate->row = -1;

	}
	else
	{
		/* no qual - do a cursor scan */
		if (festate->keyset)
		{
			festate->cursor_search_string = "SSCAN %s %s" COUNT;
			reply = redisCommand(context, festate->cursor_search_string,
								 festate->keyset, ZERO);
		}
		else if (festate->keyprefix)
		{
			festate->cursor_search_string = "SCAN %s MATCH %s*" COUNT;
			reply = redisCommand(context, festate->cursor_search_string,
								 ZERO, redis_escape_glob(festate->keyprefix));
		}
		else
		{
			festate->cursor_search_string = "SCAN %s" COUNT;
			reply = redisCommand(context, festate->cursor_search_string, ZERO);
		}
	}

	if (!reply)
	{
		redis_discard_connection(festate->context);
		ereport(ERROR,
				(errcode(ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION),
				 errmsg("failed to list keys: %s", festate->context->errstr)
				 ));
	}
	else if (reply->type == REDIS_REPLY_ERROR)
	{
		char	   *err = pstrdup(reply->str);

		freeReplyObject(reply);
		ereport(ERROR,
				(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
				 errmsg("failed somehow: %s", err)
				 ));
	}

	/* Store the additional state info */
	festate->attinmeta =
		TupleDescGetAttInMetadata(node->ss.ss_currentRelation->rd_att);

	if (festate->singleton_key)
	{
		festate->owned_reply = reply;
		festate->reply = reply;
	}
	else if (festate->row > -1 && festate->qual_value == NULL)
	{
		redisReply *cursor;

		/*
		 * SCAN and SSCAN answer with [cursor, [keys...]]. Verify that before
		 * indexing into it: a reply that is not an array has element == NULL,
		 * so reply->element[0] would dereference NULL rather than raise an
		 * error. The type mask cannot express the element count, so the arity
		 * is checked here.
		 */
		if (reply->type != REDIS_REPLY_ARRAY || reply->elements != 2)
		{
			freeReplyObject(reply);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_CREATE_REPLY),
					 errmsg("unexpected reply shape from %s",
							festate->cursor_search_string)));
		}

		cursor = reply->element[0];

		if (cursor->type == REDIS_REPLY_STRING)
		{
			if (cursor->len == 1 && cursor->str[0] == '0')
				festate->cursor_id = NULL;
			else
				festate->cursor_id = pstrdup(cursor->str);
		}
		else
		{
			int			replytype = cursor->type;

			freeReplyObject(reply);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
					 errmsg("wrong reply type %d", replytype)
					 ));
		}

		/* for cursors, this is the list of elements */
		festate->owned_reply = reply;
		festate->reply = reply->element[1];
	}
	else
	{
		/*
		 * A qual we checked with EXISTS, or a qual that failed the keyset or
		 * keyprefix test. Either way nothing iterates this reply, so it has
		 * to be released here rather than at the end of the scan.
		 */
		freeReplyObject(reply);
	}
}

/*
 * redisIterateForeignScan
 *		Read next record from the data file and store it into the
 *		ScanTupleSlot as a virtual tuple
 *
 * We have now spearated this into two streams of logic - one
 * for singleton key tables and one for multi-key tables.
 */
static TupleTableSlot *
redisIterateForeignScan(ForeignScanState *node)
{
	RedisFdwExecutionState *festate = (RedisFdwExecutionState *) node->fdw_state;

	if (festate->singleton_key)
		return redisIterateForeignScanSingleton(node);
	else
		return redisIterateForeignScanMulti(node);
}

static inline TupleTableSlot *
redisIterateForeignScanMulti(ForeignScanState *node)
{
	bool		found;
	redisReply *reply = 0;
	char	   *key;
	char	   *data = 0;
	char	  **values;
	HeapTuple	tuple;

	RedisFdwExecutionState *festate = (RedisFdwExecutionState *) node->fdw_state;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;

#ifdef DEBUG
	elog(NOTICE, "redisIterateForeignScanMulti");
#endif

	/* Cleanup */
	ExecClearTuple(slot);

	/* Get the next record, and set found */
	found = false;

	/*
	 * If we're out of rows on the cursor, fetch the next set. Keep going
	 * until we get a result back that actually has some rows.
	 */
	while (festate->cursor_id != NULL &&
		   festate->row >= festate->reply->elements)
	{
		redisReply *creply;
		redisReply *cursor;

		Assert(festate->qual_value == NULL);

		if (festate->keyset)
		{
			creply = redisCommand(festate->context,
								  festate->cursor_search_string,
								  festate->keyset, festate->cursor_id);
		}
		else if (festate->keyprefix)
		{
			creply = redisCommand(festate->context,
								  festate->cursor_search_string,
								  festate->cursor_id,
								  redis_escape_glob(festate->keyprefix));
		}
		else
		{
			creply = redisCommand(festate->context,
								  festate->cursor_search_string,
								  festate->cursor_id);
		}

		if (!creply)
		{
			redis_discard_connection(festate->context);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION),
					 errmsg("failed to list keys: %s",
							festate->context->errstr)
					 ));
		}
		else if (creply->type == REDIS_REPLY_ERROR)
		{
			char	   *err = pstrdup(creply->str);

			freeReplyObject(creply);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
					 errmsg("failed somehow: %s", err)
					 ));
		}

		if (creply->type != REDIS_REPLY_ARRAY || creply->elements != 2)
		{
			freeReplyObject(creply);
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_CREATE_REPLY),
					 errmsg("unexpected reply shape from %s",
							festate->cursor_search_string)));
		}

		cursor = creply->element[0];

		if (cursor->type == REDIS_REPLY_STRING)
		{

			MemoryContext oldcontext;
			oldcontext = MemoryContextSwitchTo(festate->mctxt);
			pfree(festate->cursor_id);
			if (cursor->len == 1 && cursor->str[0] == '0')
				festate->cursor_id = NULL;
			else
				festate->cursor_id = pstrdup(cursor->str);
			MemoryContextSwitchTo(oldcontext);
		}
		else
		{
			ereport(ERROR,
					(errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
					 errmsg("wrong reply type %d", cursor->type)
					 ));
		}

		/* the previous batch's reply is finished with */
		freeReplyObject(festate->owned_reply);
		festate->owned_reply = creply;
		festate->reply = creply->element[1];
		festate->row = 0;
	}

	/*
	 * -1 means we failed the qual test, so there are no rows or we've already
	 * processed the qual
	 */

	if (festate->row > -1 &&
		(festate->qual_value != NULL ||
		 (festate->row < festate->reply->elements)))
	{
		/*
		 * Get the row, check the result type, and handle accordingly. If it's
		 * nil, we go ahead and get the next row.
		 */
		do
		{

			key = festate->qual_value != NULL ?
				festate->qual_value :
				festate->reply->element[festate->row]->str;
			switch (festate->table_type)
			{
				case PG_REDIS_HASH_TABLE:
					reply = redisCommand(festate->context,
										 "HGETALL %s", key);
					break;
				case PG_REDIS_LIST_TABLE:
					reply = redisCommand(festate->context,
										 "LRANGE %s 0 -1", key);
					break;
				case PG_REDIS_SET_TABLE:
					reply = redisCommand(festate->context,
										 "SMEMBERS %s", key);
					break;
				case PG_REDIS_ZSET_TABLE:
					reply = redisCommand(festate->context,
										 "ZRANGE %s 0 -1", key);
					break;
				case PG_REDIS_SCALAR_TABLE:
				default:
					reply = redisCommand(festate->context,
										 "GET %s", key);
			}

			if (!reply)
			{
				freeReplyObject(festate->owned_reply);
				redis_discard_connection(festate->context);
				ereport(ERROR, (errcode(ERRCODE_FDW_UNABLE_TO_CREATE_REPLY),
						 errmsg("failed to get the value for key \"%s\": %s",
								key, festate->context->errstr)
								));
			}

			festate->row++;

		} while ((reply->type == REDIS_REPLY_NIL ||
				  reply->type == REDIS_REPLY_STATUS ||
				  reply->type == REDIS_REPLY_ERROR) &&
				 festate->qual_value == NULL &&
				 festate->row < festate->reply->elements);

		if (festate->qual_value != NULL || festate->row <= festate->reply->elements)
		{
			/*
			 * Now, deal with the different data types we might have got from
			 * Redis.
			 */

			switch (reply->type)
			{
				case REDIS_REPLY_INTEGER:
					data = (char *) palloc(sizeof(char) * 64);
					snprintf(data, 64, "%lld", reply->integer);
					found = true;
					break;

				case REDIS_REPLY_STRING:
					data = reply->str;
					found = true;
					break;

				case REDIS_REPLY_ARRAY:
					data = redis_array_to_text(reply);
					found = true;
					break;
			}
		}

		/* make sure we don't try to process the qual row twice */
		if (festate->qual_value != NULL)
			festate->row = -1;
	}

	/* Build the tuple */
	if (found)
	{
		values = (char **) palloc(sizeof(char *) * 2);
		values[0] = key;
		values[1] = data;
		tuple = BuildTupleFromCStrings(festate->attinmeta, values);
		ExecStoreHeapTuple(tuple, slot, false);
	}

	/* Cleanup */
	if (reply)
		freeReplyObject(reply);

	return slot;
}

static inline TupleTableSlot *
redisIterateForeignScanSingleton(ForeignScanState *node)
{
	bool		found;
	char	   *key = NULL;
	char	   *data = NULL;
	char	  **values;
	HeapTuple	tuple;

	RedisFdwExecutionState *festate = (RedisFdwExecutionState *) node->fdw_state;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;

#ifdef DEBUG
	elog(NOTICE, "redisIterateForeignScanSingleton");
#endif

	/* Cleanup */
	ExecClearTuple(slot);

	if (festate->row < 0)
		return slot;

	/* Get the next record, and set found */
	found = false;

	if (festate->table_type == PG_REDIS_SCALAR_TABLE)
	{
		festate->row = -1;		/* just one row for a scalar */
		switch (festate->reply->type)
		{
			case REDIS_REPLY_INTEGER:
				key = (char *) palloc(sizeof(char) * 64);
				snprintf(key, 64, "%lld", festate->reply->integer);
				found = true;
				break;

			case REDIS_REPLY_STRING:
				key = festate->reply->str;
				found = true;
				break;

			case REDIS_REPLY_ARRAY:
				freeReplyObject(festate->owned_reply);
				ereport(ERROR, (errcode(ERRCODE_FDW_UNABLE_TO_CREATE_REPLY),
								errmsg("not expecting an array for a singleton scalar table")));
				break;
		}
	}
	else if (festate->table_type == PG_REDIS_HASH_TABLE && festate->qual_value)
	{
		festate->row = -1;		/* just one row for qual'd search in a hash */
		key = festate->qual_value;
		switch (festate->reply->type)
		{
			case REDIS_REPLY_INTEGER:
				data = (char *) palloc(sizeof(char) * 64);
				snprintf(data, 64, "%lld", festate->reply->integer);
				found = true;
				break;

			case REDIS_REPLY_STRING:
				data = festate->reply->str;
				found = true;
				break;

			case REDIS_REPLY_ARRAY:
				freeReplyObject(festate->owned_reply);
				ereport(ERROR, (errcode(ERRCODE_FDW_UNABLE_TO_CREATE_REPLY),
								errmsg("not expecting an array for a single hash property: %s", festate->qual_value)));
				break;
		}
	}
	else if (festate->row < festate->reply->elements)
	{
		/* everything else comes in as an array reply type */
		found = true;
		key = festate->reply->element[festate->row]->str;
		festate->row++;
		if (festate->table_type == PG_REDIS_HASH_TABLE ||
			festate->table_type == PG_REDIS_ZSET_TABLE)
		{
			redisReply *dreply = festate->reply->element[festate->row];

			switch (dreply->type)
			{
				case REDIS_REPLY_INTEGER:
					data = (char *) palloc(sizeof(char) * 64);
					snprintf(key, 64, "%lld", dreply->integer);
					break;

				case REDIS_REPLY_STRING:
					data = dreply->str;
					break;

				case REDIS_REPLY_ARRAY:
					freeReplyObject(festate->owned_reply);
					ereport(ERROR, (errcode(ERRCODE_FDW_UNABLE_TO_CREATE_REPLY),
									errmsg("not expecting array for a hash value or zset score")
									));
					break;
			}
			festate->row++;
		}
	}

	/* Build the tuple */
	values = (char **) palloc(sizeof(char *) * 2);

	if (found)
	{
		values[0] = key;
		values[1] = data;
		tuple = BuildTupleFromCStrings(festate->attinmeta, values);
		ExecStoreHeapTuple(tuple, slot, false);
	}

	return slot;
}

/*
 * redisEndForeignScan
 *		Finish scanning foreign table and dispose objects used for this scan
 */
static void
redisEndForeignScan(ForeignScanState *node)
{
	RedisFdwExecutionState *festate = (RedisFdwExecutionState *) node->fdw_state;

#ifdef DEBUG
	elog(NOTICE, "redisEndForeignScan");
#endif

	/* if festate is NULL, we are in EXPLAIN; nothing to do */
	if (festate)
	{
		if (festate->owned_reply)
			freeReplyObject(festate->owned_reply);
	}
}

/*
 * redisReScanForeignScan
 *		Rescan table, possibly with new parameters
 */
static void
redisReScanForeignScan(ForeignScanState *node)
{
	RedisFdwExecutionState *festate = (RedisFdwExecutionState *) node->fdw_state;

#ifdef DEBUG
	elog(NOTICE, "redisReScanForeignScan");
#endif

	if (festate->row > -1)
		festate->row = 0;
}

static void
redisGetQual(Node *node, TupleDesc tupdesc, char **key, char **value, bool *pushdown)
{
	*key = NULL;
	*value = NULL;
	*pushdown = false;

	if (!node)
		return;

	if (IsA(node, OpExpr))
	{
		OpExpr	   *op = (OpExpr *) node;
		Node	   *left,
				   *right;
		Index		varattno;

		if (list_length(op->args) != 2)
			return;

		left = list_nth(op->args, 0);

		if (!IsA(left, Var))
			return;

		varattno = ((Var *) left)->varattno;

		right = list_nth(op->args, 1);

		if (IsA(right, Const))
		{
			if (((Const *) right)->consttype == TEXTOID) {
				/* And get the column and value... */
				*key = NameStr(TupleDescAttr(tupdesc, varattno - 1)->attname);
				*value = TextDatumGetCString(((Const *) right)->constvalue);

				/*
				 * We can push down this qual if: - The operatory is TEXTEQ - The
				 * qual is on the key column
				 */
				if (op->opfuncid == PROCID_TEXTEQ && strcmp(*key, "key") == 0)
					*pushdown = true;

				return;
			}
		}
	}
	return;
}

/*
 * redis_array_to_text
 *		Convert a Redis array reply to a PostgreSQL array literal string.
 *		Used for scalar text columns that receive array data from Redis.
 */
static char *
redis_array_to_text(redisReply *reply)
{
	StringInfo	res = makeStringInfo();
	bool		need_sep = false;

	appendStringInfoChar(res, '{');
	for (int i = 0; i < reply->elements; i++)
	{
		redisReply *ir = reply->element[i];

		if (need_sep)
			appendStringInfoChar(res, ',');
		need_sep = true;

		if (ir->type == REDIS_REPLY_ARRAY)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("nested array returns not yet supported")));

		switch (ir->type)
		{
			case REDIS_REPLY_STATUS:
			case REDIS_REPLY_STRING:
				{
					char	   *buff;
					char	   *crs;

					pg_verifymbstr(ir->str, ir->len, false);
					buff = palloc(ir->len * 2 + 3);
					crs = buff;
					*crs++ = '"';
					for (int j = 0; j < ir->len; j++)
					{
						if (ir->str[j] == '"' || ir->str[j] == '\\')
							*crs++ = '\\';
						*crs++ = ir->str[j];
					}
					*crs++ = '"';
					*crs = '\0';
					appendStringInfoString(res, buff);
					pfree(buff);
				}
				break;
			case REDIS_REPLY_INTEGER:
				appendStringInfo(res, "%lld", ir->integer);
				break;
			case REDIS_REPLY_NIL:
				appendStringInfoString(res, "NULL");
				break;
			default:
				break;
		}
	}
	appendStringInfoChar(res, '}');

	return res->data;
}

static void
redisAddForeignUpdateTargets(PlannerInfo *root,
							 Index rtindex,
							 RangeTblEntry *target_rte,
							 Relation target_relation)
{
	Var		   *var;

	/* assumes that this isn't attisdropped */
	Form_pg_attribute attr =
		TupleDescAttr(RelationGetDescr(target_relation), 0);

#ifdef DEBUG
	elog(NOTICE, "redisAddForeignUpdateTargets");
#endif

	/*
	 * Code adapted from  postgres_fdw
	 *
	 * In Redis, we need the key name. It's the first column in the table
	 * regardless of the table type. Knowing the key, we can update or delete
	 * it.
	 */

	/* Make a Var representing the desired value */
	var = makeVar(rtindex,
				  1,
				  attr->atttypid,
				  attr->atttypmod,
				  attr->attcollation,
				  0);
	/* register it as a row-identity column needed by this target rel */
	add_row_identity_var(root, var, rtindex, REDISMODKEYNAME);
}

/*
 * redisPlanForeignModify
 *		Plan an insert/update/delete operation on a foreign table
 */
static List *
redisPlanForeignModify(PlannerInfo *root,
					   ModifyTable *plan,
					   Index resultRelation,
					   int subplan_index)
{
	CmdType		operation = plan->operation;
	RangeTblEntry *rte = planner_rt_fetch(resultRelation, root);
	Relation	rel;
	List	   *targetAttrs = NIL;
	List	   *array_elem_list = NIL;
	TupleDesc	tupdesc;
	Oid			array_element_type = InvalidOid;

#ifdef DEBUG
	elog(NOTICE, "redisPlanForeignModify");
#endif

	/*
	 * RETURNING list not supported
	 */
	if (plan->returningLists)
		elog(ERROR, "RETURNING is not supported by this FDW");

	rel = table_open(rte->relid, NoLock);
	tupdesc = RelationGetDescr(rel);

	/* if the second attribute exists and it's an array, get the element type */
	if (tupdesc->natts > 1)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, 1);

		array_element_type = get_element_type(attr->atttypid);
	}

	array_elem_list = lappend_oid(array_elem_list, array_element_type);


	if (operation == CMD_INSERT)
	{
		int			attnum;

		for (attnum = 1; attnum <= tupdesc->natts; attnum++)
		{
			Form_pg_attribute attr = TupleDescAttr(tupdesc, attnum - 1);

			if (!attr->attisdropped)
				targetAttrs = lappend_int(targetAttrs, attnum);
		}
	}
	else if (operation == CMD_UPDATE)
	{
#if PG_VERSION_NUM >= 160000
		/* code borrowed from mysql fdw */
		RelOptInfo *rrel = find_base_rel(root, resultRelation);
		Bitmapset  *tmpset = get_rel_all_updated_cols(root, rrel);
		int	colidx = -1;
#else
		/* modifiedCols in pg < 9.5 */
		Bitmapset  *tmpset = bms_copy(rte->updatedCols);
		AttrNumber	col;
#endif
#if PG_VERSION_NUM >= 160000
		while ((colidx = bms_next_member(tmpset, colidx)) >= 0)
#else
		while ((col = bms_first_member(tmpset)) >= 0)
#endif
		{
#if PG_VERSION_NUM >= 160000
			AttrNumber col = colidx + FirstLowInvalidHeapAttributeNumber;
#else
			col += FirstLowInvalidHeapAttributeNumber;
#endif
			if (col <= InvalidAttrNumber)		/* shouldn't happen */
				elog(ERROR, "system-column update is not supported");

			targetAttrs = lappend_int(targetAttrs, col);
		}
	}

	/* nothing extra needed for DELETE - all it needs is the resjunk column */
	table_close(rel, NoLock);

	return list_make2(targetAttrs, array_elem_list);
}

/*
 * redisBeginForeignModify
 *		Begin an insert/update/delete operation on a foreign table
 */
static void
redisBeginForeignModify(ModifyTableState *mtstate,
						ResultRelInfo *rinfo,
						List *fdw_private,
						int subplan_index,
						int eflags)
{
	redisTableOptions table_options;
	redisContext *context;
	RedisFdwModifyState *fmstate;
	Relation	rel = rinfo->ri_RelationDesc;
	ListCell   *lc;
	Oid			typefnoid;
	bool		isvarlena;
	CmdType		op = mtstate->operation;
	int			n_attrs;
	List	   *array_elem_list;

#ifdef DEBUG
	elog(NOTICE, "redisBeginForeignModify");
#endif

	/* Fetch options  */
	redisGetOptions(RelationGetRelid(rel),
					&table_options);

	fmstate = (RedisFdwModifyState *) palloc0(sizeof(RedisFdwModifyState));
	rinfo->ri_FdwState = fmstate;
	fmstate->rel = rel;
	fmstate->address = table_options.address;
	fmstate->port = table_options.port;
	fmstate->keyprefix = table_options.keyprefix;
	fmstate->keyset = table_options.keyset;
	fmstate->singleton_key = table_options.singleton_key;
	fmstate->table_type = table_options.table_type;
	fmstate->target_attrs = (List *) list_nth(fdw_private, 0);

	n_attrs = list_length(fmstate->target_attrs);
	fmstate->p_flinfo = (FmgrInfo *) palloc0(sizeof(FmgrInfo) * (n_attrs + 1));
	fmstate->targetDims = (int *) palloc0(sizeof(int) * (n_attrs + 1));

	array_elem_list = (List *) list_nth(fdw_private, 1);
	fmstate->array_elem_type = list_nth_oid(array_elem_list, 0);

	fmstate->p_nums = 0;

	if (op == CMD_UPDATE || op == CMD_DELETE)
	{
		Plan	   *subplan = outerPlanState(mtstate)->plan;
		Form_pg_attribute attr = TupleDescAttr(RelationGetDescr(rel), 0);		/* key is first */

		fmstate->keyAttno = ExecFindJunkAttributeInTlist(subplan->targetlist,
														 REDISMODKEYNAME);

		getTypeOutputInfo(attr->atttypid, &typefnoid, &isvarlena);
		fmgr_info(typefnoid, &fmstate->p_flinfo[fmstate->p_nums]);
		fmstate->p_nums++;
	}

	if (op == CMD_UPDATE || op == CMD_INSERT)
	{
		fmstate->targetDims = (int *) palloc0(sizeof(int) * (n_attrs + 1));

		foreach(lc, fmstate->target_attrs)
		{
			int			attnum = lfirst_int(lc);
			Form_pg_attribute attr = TupleDescAttr(RelationGetDescr(rel), attnum - 1);
			Oid			elem = attr->attndims ?
			get_element_type(attr->atttypid) :
			attr->atttypid;

			/*
			 * most non-singleton table types require an array, not text as
			 * value
			 */
			if (op == CMD_UPDATE && attnum > 1 &&
				attr->attndims == 0 && !fmstate->singleton_key &&
				fmstate->table_type != PG_REDIS_SCALAR_TABLE)
			{
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				  errmsg("value update not supported for this type of table")
						 ));
			}

			/*
			 * If the item is an array, store the output details for its
			 * element type, otherwise for the actual type. This saves us
			 * doing lookups later on.
			 */
			fmstate->targetDims[fmstate->p_nums] = attr->attndims;
			getTypeOutputInfo(elem, &typefnoid, &isvarlena);
			fmgr_info(typefnoid, &fmstate->p_flinfo[fmstate->p_nums]);
			fmstate->p_nums++;
		}
	}

	/*
	 * Now do some sanity checking on the number of table attributes. Since we
	 * do these here we can assume everthing is OK when we do the per row
	 * functions.
	 */

	if (op == CMD_INSERT)
	{
		if (table_options.singleton_key)
		{
			if (table_options.table_type == PG_REDIS_ZSET_TABLE && fmstate->p_nums < 2)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("operation not supported for singleton zset "
								"table without priorities column")
						 ));
			else if (fmstate->p_nums != ((table_options.table_type == PG_REDIS_HASH_TABLE || table_options.table_type == PG_REDIS_ZSET_TABLE) ? 2 : 1))
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("table has incorrect number of columns: %d for type %d", fmstate->p_nums, table_options.table_type)
						 ));
		}
		else if (fmstate->p_nums != 2)
		{
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("table has incorrect number of columns")
					 ));
		}
	}
	else if (op == CMD_UPDATE)
	{
		if (table_options.singleton_key && fmstate->table_type == PG_REDIS_LIST_TABLE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("update not supported for this type of table")
					 ));
	}
	else	/* DELETE */
	{
		if (table_options.singleton_key && fmstate->table_type == PG_REDIS_LIST_TABLE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("delete not supported for this type of table")
					 ));
	}

	/*
	 * all the checks have been done but no actual work done or connections
	 * made. That makes this the right spot to return if we're doing explain
	 * only.
	 */

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	/* Connect to the server (via connection cache) */
	context = redis_get_connection(&table_options);

	fmstate->context = context;
}

static void
check_reply(redisReply *reply, redisContext *context, int allowed,
			int error_code, char *message, char *arg)
{
	char	   *err;
	char	   *xmessage;
	int         msglen;

	if (!reply)
	{
		err = pstrdup(context->errstr);

		/*
		 * Don't free context here - redis_discard_connection() discards it
		 * and reconnects on the next checkout.
		 */
		redis_discard_connection(context);
	}
	else if (reply->type == REDIS_REPLY_ERROR)
	{
		/*
		 * The connection is fine - Redis just refused the command - and the
		 * cache owns it, so leave it alone. Freeing it here would leave the
		 * cache holding a dangling pointer for the next statement to reuse.
		 */
		err = pstrdup(reply->str);
		freeReplyObject(reply);
	}
	else if (allowed != RTYPE_ANY && (allowed & RTYPE(reply->type)) == 0)
	{
		err = psprintf("unexpected reply type %d", reply->type);
		freeReplyObject(reply);
	}
	else
		return;

	msglen = strlen(message);
	xmessage = palloc(msglen + 6);
	strncpy(xmessage, message, msglen + 1);
	strcat(xmessage, ": %s");

	if (arg != NULL)
		ereport(ERROR,
				(errcode(error_code),
				 errmsg(xmessage, arg, err)
				 ));
	else
		ereport(ERROR,
				(errcode(error_code),
				 errmsg(xmessage, err)
				 ));
}

/*
 * redis_command_impl
 *		Execute a Redis command using redisCommandArgv for binary safety.
 *
 *		cmd/cmd_len: the Redis command and its length
 *		key/key_len: the Redis key and its length
 *		extra_arg/extra_len: optional argument between key and data
 *		           (e.g., field for HSET, score for ZADD), NULL/0 if not needed
 *		data/data_len: the data value and its length
 */
static redisReply *
redis_command_impl(redisContext *context,
				   const char *cmd, size_t cmd_len,
				   const char *key, size_t key_len,
				   const char *extra_arg, size_t extra_len,
				   const char *data, size_t data_len)
{
	const char *argv[4];
	size_t		argvlen[4];
	int			argc = 0;

	argv[argc] = cmd;
	argvlen[argc] = cmd_len;
	argc++;

	argv[argc] = key;
	argvlen[argc] = key_len;
	argc++;

	if (extra_arg != NULL)
	{
		argv[argc] = extra_arg;
		argvlen[argc] = extra_len;
		argc++;
	}

	argv[argc] = data;
	argvlen[argc] = data_len;
	argc++;

	return redisCommandArgv(context, argc, argv, argvlen);
}

/*
 * redis_command macro
 *		Wrapper that computes command length at compile time for string literals.
 */
#define redis_command(ctx, cmd, key, key_len, extra, extra_len, data, data_len) \
	redis_command_impl(ctx, cmd, sizeof(cmd) - 1, key, key_len, extra, extra_len, data, data_len)

/*
 * redisExecForeignInsert
 *		Insert one row into a foreign table
 */
static TupleTableSlot *
redisExecForeignInsert(EState *estate,
					   ResultRelInfo *rinfo,
					   TupleTableSlot *slot,
					   TupleTableSlot *planSlot)
{
	RedisFdwModifyState *fmstate =
	(RedisFdwModifyState *) rinfo->ri_FdwState;
	redisContext *context = fmstate->context;
	redisReply *sreply = NULL;
	bool		isnull;
	Datum		key;
	char	   *keyval;
	char	   *extraval = "";	/* hash value or zset priority */

#ifdef DEBUG
	elog(NOTICE, "redisExecForeignInsert");
#endif

	key = slot_getattr(slot, 1, &isnull);
	if (isnull)
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("cannot insert NULL key into a Redis table")
				 ));
	keyval = OutputFunctionCall(&fmstate->p_flinfo[0], key);

	if (fmstate->singleton_key)
	{
		char	   *rkeyval;

		if (fmstate->table_type == PG_REDIS_SCALAR_TABLE)
			rkeyval = fmstate->singleton_key;
		else
			rkeyval = keyval;

		/*
		 * Check if key is there using EXISTS / HEXISTS / SISMEMBER / ZRANK.
		 * It is not an error for a list type singleton as they don't have to
		 * be unique.
		 */

		switch (fmstate->table_type)
		{
			case PG_REDIS_SCALAR_TABLE:
				sreply = redisCommand(context, "EXISTS %s",		/* 1 or 0 */
									  fmstate->singleton_key);
				break;
			case PG_REDIS_HASH_TABLE:
				sreply = redis_command(context, "HEXISTS",		/* 1 or 0 */
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_SET_TABLE:
				sreply = redis_command(context, "SISMEMBER",	/* 1 or 0 */
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_ZSET_TABLE:
				sreply = redis_command(context, "ZRANK",		/* n or nil */
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_LIST_TABLE:
			default:
				break;
		}

		if (fmstate->table_type != PG_REDIS_LIST_TABLE)
		{
			bool		ok = true;

			check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER) | RTYPE(REDIS_REPLY_NIL),
						ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
						"failed checking key existence", NULL);

			if (fmstate->table_type != PG_REDIS_ZSET_TABLE)
				ok = sreply->type == REDIS_REPLY_INTEGER &&
					sreply->integer == 0;
			else
				ok = sreply->type == REDIS_REPLY_NIL;

			freeReplyObject(sreply);

			if (!ok)
			{
				ereport(ERROR,
						(errcode(ERRCODE_UNIQUE_VIOLATION),
						 errmsg("key already exists: %s", rkeyval)));
			}
		}

		/* if OK add the value using SET / HSET / SADD / ZADD / RPUSH */

		/* get the second value for appropriate table types */

		if (fmstate->table_type == PG_REDIS_ZSET_TABLE ||
			fmstate->table_type == PG_REDIS_HASH_TABLE)
		{
			Datum		extra;

			extra = slot_getattr(slot, 2, &isnull);
			if (isnull)
				ereport(ERROR,
						(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						 errmsg("cannot insert NULL value into a Redis table")
						 ));
			extraval = OutputFunctionCall(&fmstate->p_flinfo[1], extra);
		}

		switch (fmstate->table_type)
		{
			case PG_REDIS_SCALAR_TABLE:
				sreply = redis_command(context, "SET",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_SET_TABLE:
				sreply = redis_command(context, "SADD",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_LIST_TABLE:
				sreply = redis_command(context, "RPUSH",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_HASH_TABLE:
				sreply = redis_command(context, "HSET",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   keyval, strlen(keyval), extraval, strlen(extraval));
				break;
			case PG_REDIS_ZSET_TABLE:
				/*
				 * score comes BEFORE value in ZADD, which seems slightly
				 * perverse
				 */
				sreply = redis_command(context, "ZADD",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   extraval, strlen(extraval), keyval, strlen(keyval));
				break;
			default:
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("insert not supported for this type of table")
						 ));
		}

		check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER) | RTYPE(REDIS_REPLY_STATUS),
					ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
					"cannot insert value for key %s", keyval);
		freeReplyObject(sreply);
	}
	else /* if not a singleton key table */
	{
		char	   *valueval = NULL;
		int			nitems;
		Datum	   *elements;
		bool	   *nulls;
		int16		typlen;
		bool		typbyval;
		char		typalign;
		bool		is_array = fmstate->array_elem_type != InvalidOid;
		Datum		value = slot_getattr(slot, 2, &isnull);

		if (isnull)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("cannot insert NULL into a Redis table")
					 ));

		if (is_array && fmstate->table_type == PG_REDIS_SCALAR_TABLE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("cannot insert array into into a Redis scalar table")
					 ));
		else if (!is_array && fmstate->table_type != PG_REDIS_SCALAR_TABLE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("cannot insert into this type of Redis table - needs an array")
					 ));

		/* make sure the key has the right prefix, if any */
		if (fmstate->keyprefix &&
			strncmp(keyval, fmstate->keyprefix,
					strlen(fmstate->keyprefix)) != 0)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("key '%s' does not match table key prefix '%s'",
							keyval, fmstate->keyprefix)
					 ));

		/* Check if key is there using EXISTS  */
		{
			const char *argv[2] = {"EXISTS", keyval};
			size_t		argvlen[2] = {6, strlen(keyval)};

			sreply = redisCommandArgv(context, 2, argv, argvlen);
		}
		check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER), ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
					"failed checking key existence", NULL);

		if (sreply->type != REDIS_REPLY_INTEGER || sreply->integer != 0)
		{
			freeReplyObject(sreply);
			ereport(ERROR,
					(errcode(ERRCODE_UNIQUE_VIOLATION),
					 errmsg("key already exists: %s", keyval)));
		}

		freeReplyObject(sreply);

		/* if OK add values using SET / HSET / SADD / ZADD / RPUSH */

		if (fmstate->table_type == PG_REDIS_SCALAR_TABLE)
		{
			/* everything else will be an array */
			valueval = OutputFunctionCall(&fmstate->p_flinfo[1], value);
		}
		else
		{
			int			i;

			get_typlenbyvalalign(fmstate->array_elem_type,
								 &typlen, &typbyval, &typalign);

			deconstruct_array(DatumGetArrayTypeP(value),
							  fmstate->array_elem_type, typlen, typbyval,
							  typalign, &elements, &nulls,
							  &nitems);

			if (nitems == 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot store empty list in a Redis table")
						 ));

			if (fmstate->table_type == PG_REDIS_HASH_TABLE && nitems % 2 != 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot decompose odd number of items into a Redis hash")
						 ));

			for (i = 0; i < nitems; i++)
			{
				if (nulls[i])
					ereport(ERROR,
							(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							 errmsg("cannot insert NULL into a Redis table")
							 ));
			}
		}

		switch (fmstate->table_type)
		{
			case PG_REDIS_SCALAR_TABLE:
				sreply = redis_command(context, "SET",
									   keyval, strlen(keyval),
									   NULL, 0, valueval, strlen(valueval));
				check_reply(sreply, context, RTYPE(REDIS_REPLY_STATUS),
							ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
							"could not add key %s", keyval);
				freeReplyObject(sreply);
				break;
			case PG_REDIS_SET_TABLE:
				{
					int			i;

					for (i = 0; i < nitems; i++)
					{
						valueval = OutputFunctionCall(&fmstate->p_flinfo[1],
													  elements[i]);
						sreply = redis_command(context, "SADD",
											   keyval, strlen(keyval),
											   NULL, 0, valueval, strlen(valueval));
						check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add set member %s", valueval);
						freeReplyObject(sreply);
					}
				}
				break;
			case PG_REDIS_LIST_TABLE:
				{
					int			i;

					for (i = 0; i < nitems; i++)
					{
						valueval = OutputFunctionCall(&fmstate->p_flinfo[1],
													  elements[i]);
						sreply = redis_command(context, "RPUSH",
											   keyval, strlen(keyval),
											   NULL, 0, valueval, strlen(valueval));
						check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add value %s", valueval);
					}
				}
				break;
			case PG_REDIS_HASH_TABLE:
				{
					int			i;
					char	   *hk,
							   *hv;

					for (i = 0; i < nitems; i += 2)
					{
						hk = OutputFunctionCall(&fmstate->p_flinfo[1],
												elements[i]);
						hv = OutputFunctionCall(&fmstate->p_flinfo[1],
												elements[i + 1]);
						/* HSET needs 4 args: key, field, value - use custom call */
						{
							const char *argv[4];
							size_t		argvlen[4];

							argv[0] = "HSET";
							argvlen[0] = 4;
							argv[1] = keyval;
							argvlen[1] = strlen(keyval);
							argv[2] = hk;
							argvlen[2] = strlen(hk);
							argv[3] = hv;
							argvlen[3] = strlen(hv);
							sreply = redisCommandArgv(context, 4, argv, argvlen);
						}
						check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add key %s", hk);
						freeReplyObject(sreply);
					}
				}
				break;
			case PG_REDIS_ZSET_TABLE:
				{
					int			i;
					char		ibuff[100];

					for (i = 0; i < nitems; i++)
					{
						valueval = OutputFunctionCall(&fmstate->p_flinfo[1],
													  elements[i]);
						sprintf(ibuff, "%d", i);

						/*
						 * score comes BEFORE value in ZADD, which seems
						 * slightly perverse
						 */
						sreply = redis_command(context, "ZADD",
											   keyval, strlen(keyval),
											   ibuff, strlen(ibuff), valueval, strlen(valueval));
						check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add key %s", valueval);
						freeReplyObject(sreply);
					}
				}
				break;
			default:
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("insert not supported for this type of table")
						 ));
		}

		/* if it's a keyset organized table, add key to keyset using SADD */

		if (fmstate->keyset)
		{
			sreply = redisCommand(context, "SADD %s %s",
								  fmstate->keyset, keyval);
			check_reply(sreply, context, RTYPE(REDIS_REPLY_INTEGER),
						ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
						"could not add keyset element %s", valueval);
			freeReplyObject(sreply);
		}
	}
	return slot;
}

/*
 * redisExecForeignDelete
 *		Delete one row from a foreign table
 */
static TupleTableSlot *
redisExecForeignDelete(EState *estate,
					   ResultRelInfo *rinfo,
					   TupleTableSlot *slot,
					   TupleTableSlot *planSlot)
{
	RedisFdwModifyState *fmstate =
	(RedisFdwModifyState *) rinfo->ri_FdwState;
	redisContext *context = fmstate->context;
	redisReply *reply = NULL;
	bool		isNull;
	Datum		datum;
	char	   *keyval;

#ifdef DEBUG
	elog(NOTICE, "redisExecForeignDelete");
#endif

	/* Get the key that was passed up as a resjunk column */
	datum = ExecGetJunkAttribute(planSlot,
								 fmstate->keyAttno,
								 &isNull);

	keyval = OutputFunctionCall(&fmstate->p_flinfo[0], datum);

	/* elog(NOTICE,"deleting keyval %s",keyval); */

	if (fmstate->singleton_key)
	{
		switch (fmstate->table_type)
		{
			case PG_REDIS_SCALAR_TABLE:
				reply = redisCommand(context, "DEL %s",
									 fmstate->singleton_key);
				break;
			case PG_REDIS_SET_TABLE:
				reply = redis_command(context, "SREM",
									  fmstate->singleton_key, strlen(fmstate->singleton_key),
									  NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_HASH_TABLE:
				reply = redis_command(context, "HDEL",
									  fmstate->singleton_key, strlen(fmstate->singleton_key),
									  NULL, 0, keyval, strlen(keyval));
				break;
			case PG_REDIS_ZSET_TABLE:
				reply = redis_command(context, "ZREM",
									  fmstate->singleton_key, strlen(fmstate->singleton_key),
									  NULL, 0, keyval, strlen(keyval));
				break;
			default:
				/* Note: List table has already generated an error */
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("delete not supported for this type of table")
						 ));
		}
	}
	else	/* not a singleton */
	{
		/* use DEL regardless of table type */
		reply = redisCommand(context, "DEL %s", keyval);
	}

	check_reply(reply, context, RTYPE(REDIS_REPLY_INTEGER),
				ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
				"failed to delete key %s", keyval);
	freeReplyObject(reply);

	if (fmstate->keyset)
	{
		reply = redisCommand(context, "SREM %s %s",
							 fmstate->keyset, keyval);

		check_reply(reply, context, RTYPE(REDIS_REPLY_INTEGER),
					ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
					"failed to delete keyset element %s", keyval);
		freeReplyObject(reply);

	}

	return slot;
}

/*
 * redisExecForeignUpdate
 *		Update one row in a foreign table
 */
static TupleTableSlot *
redisExecForeignUpdate(EState *estate,
					   ResultRelInfo *rinfo,
					   TupleTableSlot *slot,
					   TupleTableSlot *planSlot)
{
	RedisFdwModifyState *fmstate =
	(RedisFdwModifyState *) rinfo->ri_FdwState;
	redisContext *context = fmstate->context;
	redisReply *ereply = NULL;
	Datum		datum;
	char	   *keyval;
	char	   *newkey;
	char	   *newval = NULL;
	char	  **array_vals = NULL;
	bool		isNull;
	ListCell   *lc = NULL;
	int			flslot = 1;
	int			nitems = 0;

#ifdef DEBUG
	elog(NOTICE, "redisExecForeignUpdate");
#endif

	/* Get the key that was passed up as a resjunk column */
	datum = ExecGetJunkAttribute(planSlot,
								 fmstate->keyAttno,
								 &isNull);

	keyval = OutputFunctionCall(&fmstate->p_flinfo[0], datum);

	newkey = keyval;

	Assert(keyval != NULL);

	/* extract the updated values */
	foreach(lc, fmstate->target_attrs)
	{
		int			attnum = lfirst_int(lc);

		datum = slot_getattr(slot, attnum, &isNull);

		if (isNull)
			elog(ERROR, "NULL update not supported");

		if (attnum == 1)
		{
			newkey = OutputFunctionCall(&fmstate->p_flinfo[flslot], datum);
		}
		else if (fmstate->singleton_key ||
				 fmstate->table_type == PG_REDIS_SCALAR_TABLE)
		{
			/*
			 * non-singleton scalar value, or singleton hash value, or
			 * singleton zset priority.
			 */
			newval = OutputFunctionCall(&fmstate->p_flinfo[flslot], datum);
		}
		else
		{
			/*
			 * must be a non-singleton non-scalar table. so it must be an
			 * array.
			 */
			int			i;
			Datum	   *elements;
			bool	   *nulls;
			int16		typlen;
			bool		typbyval;
			char		typalign;

			get_typlenbyvalalign(fmstate->array_elem_type,
								 &typlen, &typbyval, &typalign);

			deconstruct_array(DatumGetArrayTypeP(datum),
							  fmstate->array_elem_type, typlen, typbyval,
							  typalign, &elements, &nulls,
							  &nitems);

			if (nitems == 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot store empty list in a Redis table")
						 ));

			if (fmstate->table_type == PG_REDIS_HASH_TABLE && nitems % 2 != 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot decompose odd number of items into a Redis hash")
						 ));

			array_vals = palloc(nitems * sizeof(char *));

			for (i = 0; i < nitems; i++)
			{
				if (nulls[i])
					ereport(ERROR,
							(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							 errmsg("cannot set NULL in a Redis table")
							 ));

				array_vals[i] = OutputFunctionCall(&fmstate->p_flinfo[flslot],
												   elements[i]);
			}
		}

		flslot++;
	}

	/* now we have all the data we need */

	/* if newkey = keyval then we're not updating the key */
	if (strcmp(keyval, newkey) != 0)
	{
		bool		ok = true;

		ereply = NULL;

		/* make sure the new key doesn't exist */
		if (!fmstate->singleton_key)
		{
			ereply = redisCommand(context, "EXISTS %s", newkey);
			check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
						ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
						"failed checking key existence %s", newkey);
			ok = ereply->type == REDIS_REPLY_INTEGER && ereply->integer == 0;
		}
		else
		{
			switch (fmstate->table_type)
			{
				case PG_REDIS_SET_TABLE:
					ereply = redisCommand(context, "SISMEMBER %s %s",
										  fmstate->singleton_key, newkey);
					break;
				case PG_REDIS_ZSET_TABLE:
					ereply = redisCommand(context, "ZRANK %s %s",
										  fmstate->singleton_key, newkey);
					break;
				case PG_REDIS_HASH_TABLE:
					ereply = redisCommand(context, "HEXISTS %s %s",
										  fmstate->singleton_key, newkey);
					break;
				default:
					break;
			}
			if (fmstate->table_type != PG_REDIS_SCALAR_TABLE)
			{
				check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER) | RTYPE(REDIS_REPLY_NIL),
							ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
							"failed checking key existence %s", keyval);

				if (fmstate->table_type != PG_REDIS_ZSET_TABLE)
					ok = ereply->type == REDIS_REPLY_INTEGER &&
						ereply->integer == 0;
				else
					ok = ereply->type == REDIS_REPLY_NIL;
			}
		}

		if (ereply != NULL)
			freeReplyObject(ereply);

		if (!ok)
			ereport(ERROR,
					(errcode(ERRCODE_UNIQUE_VIOLATION),
					 errmsg("key already exists: %s", newkey)));

		if (!fmstate->singleton_key)
		{
			if (fmstate->keyprefix && strncmp(fmstate->keyprefix, newkey,
											strlen(fmstate->keyprefix)) != 0)
				ereport(ERROR,
						(errcode(ERRCODE_UNIQUE_VIOLATION),
					  errmsg("key prefix condition violation: %s", newkey)));

			ereply = redisCommand(context, "RENAME %s %s", keyval, newkey);

			check_reply(ereply, context, RTYPE(REDIS_REPLY_STATUS),
						ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
						"failure renaming key %s", keyval);
			freeReplyObject(ereply);

			if (newval && fmstate->table_type == PG_REDIS_SCALAR_TABLE)
			{
				ereply = redis_command(context, "SET",
									   newkey, strlen(newkey),
									   NULL, 0, newval, strlen(newval));

				check_reply(ereply, context, RTYPE(REDIS_REPLY_STATUS),
							ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
							"updating key %s", newkey);
				freeReplyObject(ereply);
			}

			if (fmstate->keyset)
			{
				/*
				 * Add the new element before removing the old one. Redis
				 * gives us nothing to roll back with, so if the add fails
				 * the remove must not already have happened - otherwise a
				 * failed UPDATE drops the key from the keyset and the row
				 * disappears. The reverse order is safe: the new key differs
				 * from the old one and is known not to be present, because
				 * we only reach here past the key comparison and the
				 * duplicate check.
				 */
				ereply = redisCommand(context, "SADD %s %s", fmstate->keyset,
									  newkey);

				check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
							ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
							"adding keyset element %s", newkey);
				freeReplyObject(ereply);

				ereply = redisCommand(context, "SREM %s %s", fmstate->keyset,
									  keyval);
				check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
							ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
							"deleting keyset element %s", keyval);
				freeReplyObject(ereply);			}
		}
		else	/* is a singleton */
		{
			switch (fmstate->table_type)
			{
				case PG_REDIS_SCALAR_TABLE:
					ereply = redis_command(context, "SET",
										   fmstate->singleton_key, strlen(fmstate->singleton_key),
										   NULL, 0, newkey, strlen(newkey));
					check_reply(ereply, context, RTYPE(REDIS_REPLY_STATUS),
								ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
								"setting value %s", newkey);
					freeReplyObject(ereply);
					break;
				case PG_REDIS_SET_TABLE:
					/* add before removing - see the keyset case above */
					ereply = redis_command(context, "SADD",
										   fmstate->singleton_key, strlen(fmstate->singleton_key),
										   NULL, 0, newkey, strlen(newkey));
					check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
								ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
								"setting value %s", newkey);
					freeReplyObject(ereply);
					ereply = redis_command(context, "SREM",
										   fmstate->singleton_key, strlen(fmstate->singleton_key),
										   NULL, 0, keyval, strlen(keyval));
					check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
								ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
								"removing value %s", keyval);
					freeReplyObject(ereply);
					break;
				case PG_REDIS_ZSET_TABLE:
					{
						char	   *priority = newval;

						if (!priority)
						{
							ereply = redis_command(context, "ZSCORE",
												   fmstate->singleton_key, strlen(fmstate->singleton_key),
												   NULL, 0, keyval, strlen(keyval));
							check_reply(ereply, context, RTYPE(REDIS_REPLY_STRING),
									  ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
										"getting score for key %s", keyval);
							priority = pstrdup(ereply->str);
							freeReplyObject(ereply);
						}
						/*
						 * Add before removing - see the keyset case above.
						 * The score was read from the old member further up,
						 * so it is already in hand and the add cannot need
						 * the old member to still exist.
						 */
						ereply = redis_command(context, "ZADD",
											   fmstate->singleton_key, strlen(fmstate->singleton_key),
											   priority, strlen(priority), newkey, strlen(newkey));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"setting element %s", newkey);
						freeReplyObject(ereply);

						ereply = redis_command(context, "ZREM",
											   fmstate->singleton_key, strlen(fmstate->singleton_key),
											   NULL, 0, keyval, strlen(keyval));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"removing set element %s", keyval);
						freeReplyObject(ereply);
					}
					break;
				case PG_REDIS_HASH_TABLE:
					{
						char	   *nval = newval;

						if (!nval)
						{
							ereply = redis_command(context, "HGET",
												   fmstate->singleton_key, strlen(fmstate->singleton_key),
												   NULL, 0, keyval, strlen(keyval));
							check_reply(ereply, context, RTYPE(REDIS_REPLY_STRING),
									  ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
										"fetching value for key %s", keyval);
							nval = pstrdup(ereply->str);
							freeReplyObject(ereply);
						}
						ereply = redis_command(context, "HDEL",
											   fmstate->singleton_key, strlen(fmstate->singleton_key),
											   NULL, 0, keyval, strlen(keyval));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"removing hash element %s", keyval);
						freeReplyObject(ereply);

						ereply = redis_command(context, "HSET",
											   fmstate->singleton_key, strlen(fmstate->singleton_key),
											   newkey, strlen(newkey), nval, strlen(nval));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"adding hash element %s", newkey);
						freeReplyObject(ereply);
					}
					break;
				default:
					break;
			}
		}
	}	/* no key update */
	else if (newval)
	{
		if (!fmstate->singleton_key)
		{
			Assert(fmstate->table_type == PG_REDIS_SCALAR_TABLE);
			ereply = redis_command(context, "SET",
								   keyval, strlen(keyval),
								   NULL, 0, newval, strlen(newval));
		}
		else
		{
			if (fmstate->table_type == PG_REDIS_ZSET_TABLE)
				ereply = redis_command(context, "ZADD",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   newval, strlen(newval), keyval, strlen(keyval));
			else if (fmstate->table_type == PG_REDIS_HASH_TABLE)
				ereply = redis_command(context, "HSET",
									   fmstate->singleton_key, strlen(fmstate->singleton_key),
									   keyval, strlen(keyval), newval, strlen(newval));
			else
				elog(ERROR, "impossible update");		/* should not happen */
		}

		check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER) | RTYPE(REDIS_REPLY_STATUS),
					ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
					"setting key %s", keyval);
		freeReplyObject(ereply);
	}

	if (array_vals)
	{

		Assert(!fmstate->singleton_key);

		{
			const char *argv[2] = {"DEL", newkey};
			size_t		argvlen[2] = {3, strlen(newkey)};

			ereply = redisCommandArgv(context, 2, argv, argvlen);
		}
		check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
					ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
					"could not delete key %s", newkey);
		freeReplyObject(ereply);

		switch (fmstate->table_type)
		{
			case PG_REDIS_SET_TABLE:
				{
					int			i;

					for (i = 0; i < nitems; i++)
					{
						ereply = redis_command(context, "SADD",
											   newkey, strlen(newkey),
											   NULL, 0, array_vals[i], strlen(array_vals[i]));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add element %s", array_vals[i]);
						freeReplyObject(ereply);
					}
				}
				break;
			case PG_REDIS_LIST_TABLE:
				{
					int			i;

					for (i = 0; i < nitems; i++)
					{
						ereply = redis_command(context, "RPUSH",
											   newkey, strlen(newkey),
											   NULL, 0, array_vals[i], strlen(array_vals[i]));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add value %s", array_vals[i]);
						freeReplyObject(ereply);
					}
				}
				break;
			case PG_REDIS_HASH_TABLE:
				{
					int			i;
					char	   *hk,
							   *hv;

					for (i = 0; i < nitems; i += 2)
					{
						hk = array_vals[i];
						hv = array_vals[i + 1];
						/* HSET needs 4 args: key, field, value - use custom call */
						{
							const char *argv[4];
							size_t		argvlen[4];

							argv[0] = "HSET";
							argvlen[0] = 4;
							argv[1] = newkey;
							argvlen[1] = strlen(newkey);
							argv[2] = hk;
							argvlen[2] = strlen(hk);
							argv[3] = hv;
							argvlen[3] = strlen(hv);
							ereply = redisCommandArgv(context, 4, argv, argvlen);
						}
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add key %s", hk);
						freeReplyObject(ereply);
					}
				}
				break;
			case PG_REDIS_ZSET_TABLE:
				{
					int			i;
					char		ibuff[100];
					char	   *zval;

					for (i = 0; i < nitems; i++)
					{
						zval = array_vals[i];
						sprintf(ibuff, "%d", i);

						/*
						 * score comes BEFORE value in ZADD, which seems
						 * slightly perverse
						 */
						ereply = redis_command(context, "ZADD",
											   newkey, strlen(newkey),
											   ibuff, strlen(ibuff), zval, strlen(zval));
						check_reply(ereply, context, RTYPE(REDIS_REPLY_INTEGER),
									ERRCODE_FDW_UNABLE_TO_CREATE_EXECUTION,
									"could not add key %s", zval);
						freeReplyObject(ereply);
					}
				}
				break;
			default:
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("update not supported for this type of table")
						 ));
		}

	}
	return slot;
}

/*
 * redisEndForeignModify
 *		Finish an insert/update/delete operation on a foreign table
 */
static void
redisEndForeignModify(EState *estate,
					  ResultRelInfo *rinfo)
{
#ifdef DEBUG
	elog(NOTICE, "redisEndForeignModify");
#endif
}

/*
 * redis_fdw_version
 *		Gets source code version of this FDW
 */
Datum
redis_fdw_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(REDIS_FDW_CODE_VERSION);
}

/*
 * redis_fdw_hiredis_version
 *		Gets used hiredis source code version
 */
Datum
redis_fdw_hiredis_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(HIREDIS_MAJOR * 10000 + HIREDIS_MINOR * 100 + HIREDIS_PATCH);
}
