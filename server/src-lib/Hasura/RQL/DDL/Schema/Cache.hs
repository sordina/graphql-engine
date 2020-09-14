{-# LANGUAGE Arrows           #-}
{-# LANGUAGE OverloadedLabels #-}

{-| Top-level functions concerned specifically with operations on the schema cache, such as
rebuilding it from the catalog and incorporating schema changes. See the module documentation for
"Hasura.RQL.DDL.Schema" for more details.

__Note__: this module is __mutually recursive__ with other @Hasura.RQL.DDL.Schema.*@ modules, which
both define pieces of the implementation of building the schema cache and define handlers that
trigger schema cache rebuilds. -}
module Hasura.RQL.DDL.Schema.Cache
  ( RebuildableSchemaCache
  , MetadataStateResult(..)
  , lastBuiltSchemaCache
  , buildRebuildableSchemaCache
  , CacheRWT
  , runCacheRWT

  , withMetadataCheck
  ) where

import           Hasura.Prelude

import qualified Data.Environment                         as Env
import qualified Data.HashMap.Strict.Extended             as M
import qualified Data.HashSet                             as HS
import qualified Data.Text                                as T
import qualified Database.PG.Query                        as Q

import           Control.Arrow.Extended
import           Control.Lens                             hiding ((.=))
import           Control.Monad.Unique
import           Data.Aeson
import           Data.List                                (nub)

import qualified Hasura.Incremental                       as Inc

import           Hasura.Db
import           Hasura.GraphQL.Execute.Types
import           Hasura.GraphQL.Schema                    (buildGQLContext)
import           Hasura.RQL.DDL.Action
import           Hasura.RQL.DDL.CustomTypes
import           Hasura.RQL.DDL.Deps
import           Hasura.RQL.DDL.EventTrigger
import           Hasura.RQL.DDL.RemoteSchema
import           Hasura.RQL.DDL.ScheduledTrigger
import           Hasura.RQL.DDL.Schema.Cache.Common
import           Hasura.RQL.DDL.Schema.Cache.Dependencies
import           Hasura.RQL.DDL.Schema.Cache.Fields
import           Hasura.RQL.DDL.Schema.Cache.Permission
import           Hasura.RQL.DDL.Schema.Catalog
import           Hasura.RQL.DDL.Schema.Diff
import           Hasura.RQL.DDL.Schema.Function
import           Hasura.RQL.DDL.Schema.Source             (resolveSource)
import           Hasura.RQL.DDL.Schema.Table
import           Hasura.RQL.DDL.Utils                     (clearHdbViews)
import           Hasura.RQL.Types                         hiding (tmTable)
import           Hasura.Server.Version                    (HasVersion)
import           Hasura.SQL.Types

buildRebuildableSchemaCache
  :: ( HasVersion, MonadIO m, MonadUnique m, MonadError QErr m
     , HasHttpManager m, HasSQLGenCtx m, MonadMetadata m
     , HasDefaultSource m
     )
  => Env.Environment
  -> m (RebuildableSchemaCache m)
buildRebuildableSchemaCache env = do
  metadata <- fetchMetadata
  result <- flip runReaderT CatalogSync $
    Inc.build (buildSchemaCacheRule env) (metadata, initialInvalidationKeys)
  pure $ RebuildableSchemaCache (Inc.result result) initialInvalidationKeys (Inc.rebuildRule result)

newtype CacheRWT m a
  -- The CacheInvalidations component of the state could actually be collected using WriterT, but
  -- WriterT implementations prior to transformers-0.5.6.0 (which added
  -- Control.Monad.Trans.Writer.CPS) are leaky, and we don’t have that yet.
  = CacheRWT (StateT (RebuildableSchemaCache m, CacheInvalidations) m a)
  deriving
    ( Functor, Applicative, Monad, MonadIO, MonadUnique, MonadReader r, MonadError e, MonadTx
    , UserInfoM, HasHttpManager, HasSQLGenCtx, HasSystemDefined, MonadMetadata)

runCacheRWT
  :: Functor m
  => RebuildableSchemaCache m -> CacheRWT m a -> m (a, RebuildableSchemaCache m, CacheInvalidations)
runCacheRWT cache (CacheRWT m) =
  runStateT m (cache, mempty) <&> \(v, (newCache, invalidations)) -> (v, newCache, invalidations)

instance MonadTrans CacheRWT where
  lift = CacheRWT . lift

-- instance (Monad m) => TableCoreInfoRM (CacheRWT m)
instance (Monad m) => CacheRM (CacheRWT m) where
  askSchemaCache = CacheRWT $ gets (lastBuiltSchemaCache . fst)

instance (MonadIO m, MonadMetadata m) => CacheRWM (CacheRWT m) where
  buildSchemaCacheWithOptions buildReason invalidations metadataModifier = CacheRWT do
    (RebuildableSchemaCache _ invalidationKeys rule, oldInvalidations) <- get
    let newInvalidationKeys = invalidateKeys invalidations invalidationKeys
    metadata <- fetchMetadata
    let modifiedMetadata = (unMetadataModifier metadataModifier) metadata
    -- catalogMetadata <- buildCatalogMetadata modifiedMetadata
    result <- lift $ flip runReaderT buildReason $
      Inc.build rule (modifiedMetadata, newInvalidationKeys)
    let schemaCache = Inc.result result
        prunedInvalidationKeys = pruneInvalidationKeys schemaCache newInvalidationKeys
        !newCache = RebuildableSchemaCache schemaCache prunedInvalidationKeys (Inc.rebuildRule result)
        !newInvalidations = oldInvalidations <> invalidations
    when (metadata /= modifiedMetadata) $ updateMetadata modifiedMetadata
    put (newCache, newInvalidations)
    where
      -- Prunes invalidation keys that no longer exist in the schema to avoid leaking memory by
      -- hanging onto unnecessary keys.
      pruneInvalidationKeys schemaCache = over ikRemoteSchemas $ M.filterWithKey \name _ ->
        -- see Note [Keep invalidation keys for inconsistent objects]
        name `elem` getAllRemoteSchemas schemaCache

buildSchemaCacheRule
  -- Note: by supplying BuildReason via MonadReader, it does not participate in caching, which is
  -- what we want!
  :: ( HasVersion, ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
     , MonadIO m, MonadUnique m, MonadError QErr m
     , MonadReader BuildReason m, HasHttpManager m, HasSQLGenCtx m
     , HasDefaultSource m
     )
  => Env.Environment
  -> (Metadata, InvalidationKeys) `arr` SchemaCache
buildSchemaCacheRule env = proc (metadata, invalidationKeys) -> do
  invalidationKeysDep <- Inc.newDependency -< invalidationKeys

  -- Step 1: Process metadata and collect dependency information.
  (outputs, collectedInfo) <-
    runWriterA buildAndCollectInfo -< (metadata, invalidationKeysDep)
  let (inconsistentObjects, unresolvedDependencies) = partitionCollectedInfo collectedInfo

  -- Step 2: Resolve dependency information and drop dangling dependents.
  (resolvedOutputs, dependencyInconsistentObjects, resolvedDependencies) <-
    resolveDependencies -< (outputs, unresolvedDependencies)

  let postgresCache = M.map (\(SourceOutput tables functions config) -> PGSourceSchemaCache tables functions config)
                      $ _boSources resolvedOutputs

  -- Step 3: Build the GraphQL schema.
  (gqlContext, gqlSchemaInconsistentObjects) <- runWriterA buildGQLContext -<
    ( QueryHasura
    , postgresCache
    , (_boRemoteSchemas resolvedOutputs)
    , (_boActions resolvedOutputs)
    , (_actNonObjects $ _boCustomTypes resolvedOutputs)
    )

  -- Step 4: Build the relay GraphQL schema
  (relayContext, relaySchemaInconsistentObjects) <- runWriterA buildGQLContext -<
    ( QueryRelay
    , postgresCache
    , (_boRemoteSchemas resolvedOutputs)
    , (_boActions resolvedOutputs)
    , (_actNonObjects $ _boCustomTypes resolvedOutputs)
    )

  returnA -< SchemaCache
    { scPostgres = postgresCache
    , scActions = _boActions resolvedOutputs
    -- TODO this is not the right value: we should track what part of the schema
    -- we can stitch without consistencies, I think.
    , scRemoteSchemas = fmap fst (_boRemoteSchemas resolvedOutputs) -- remoteSchemaMap
    , scAllowlist = _boAllowlist resolvedOutputs
    -- , scCustomTypes = _boCustomTypes resolvedOutputs
    , scGQLContext = fst gqlContext
    , scUnauthenticatedGQLContext = snd gqlContext
    , scRelayContext = fst relayContext
    , scUnauthenticatedRelayContext = snd relayContext
    -- , scGCtxMap = gqlSchema
    -- , scDefaultRemoteGCtx = remoteGQLSchema
    , scDepMap = resolvedDependencies
    , scCronTriggers = _boCronTriggers resolvedOutputs
    , scInconsistentObjs =
           inconsistentObjects
        <> dependencyInconsistentObjects
        <> toList gqlSchemaInconsistentObjects
        <> toList relaySchemaInconsistentObjects
    }
  where
    buildSource
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
         , ArrowWriter (Seq CollectedInfo) arr, MonadReader BuildReason m
         , HasSQLGenCtx m, MonadIO m, MonadError QErr m)
      => ( SourceMetadata
         , PGSourceConfig
         , PostgresTablesMetadata
         , PostgresFunctionsMetadata
         , RemoteSchemaMap
         , Inc.Dependency InvalidationKeys
         ) `arr` SourceOutput
    buildSource = proc (sourceMetadata, sourceConfig, pgTables, pgFunctions, remoteSchemaMap, invalidationKeys) -> do
      let SourceMetadata source tables functions _ = sourceMetadata
          (tableInputs, nonColumnInputs, permissions) = unzip3 $ map mkTableInputs $ M.elems tables
          eventTriggers = map (_tmTable &&& (M.elems . _tmEventTriggers)) (M.elems tables)
          -- HashMap k a -> HashMap k b -> HashMap k (a, b)
          alignTableMap lMap rMap =
            let alignFn = \case
                  This _    -> Nothing
                  That _    -> Nothing
                  These a b -> Just (a, b)
            in M.catMaybes $ alignWith alignFn lMap rMap

      -- tables
      tableRawInfos <- buildTableCache -< (source, sourceConfig, pgTables, tableInputs, Inc.selectD #_ikMetadata invalidationKeys)

      -- relationships and computed fields
      let nonColumnsByTable = mapFromL _nctiTable nonColumnInputs
      tableCoreInfos <-
        (| Inc.keyed (\_ (tableRawInfo, nonColumnInput) -> do
             let columns = _tciFieldInfoMap tableRawInfo
             allFields <- addNonColumnFields -< (source, tableRawInfos, columns, remoteSchemaMap, pgFunctions, nonColumnInput)
             returnA -< (tableRawInfo {_tciFieldInfoMap = allFields}))
         |) (tableRawInfos `alignTableMap` nonColumnsByTable)

      tableCoreInfosDep <- Inc.newDependency -< tableCoreInfos
      -- permissions and event triggers
      tableCache <-
        (| Inc.keyed (\_ ((tableCoreInfo, permissionInputs), (_, eventTriggerConfs)) -> do
             let tableFields = _tciFieldInfoMap tableCoreInfo
             permissionInfos <- buildTablePermissions -< (source, tableCoreInfosDep, tableFields, permissionInputs)
             eventTriggerInfos <- buildTableEventTriggers -< (source, sourceConfig, tableCoreInfo, eventTriggerConfs)
             returnA -< TableInfo tableCoreInfo permissionInfos eventTriggerInfos
            )
         |) (tableCoreInfos `alignTableMap` mapFromL _tpiTable permissions `alignTableMap` mapFromL fst eventTriggers)

      -- sql functions
      functionCache <- (mapFromL _fmFunction (M.elems functions) >- returnA)
        >-> (| Inc.keyed (\_ (FunctionMetadata qf config) -> do
                 let systemDefined = SystemDefined False
                     definition = toJSON $ TrackFunction qf
                     metadataObject = MetadataObject (MOSourceObjId source $ SMOFunction qf) definition
                     schemaObject = SOSourceObj source $ SOIFunction qf
                     addFunctionContext e = "in function " <> qf <<> ": " <> e
                 (| withRecordInconsistency (
                    (| modifyErrA (do
                         let funcDefs = fromMaybe [] $ M.lookup qf pgFunctions
                         rawfi <- bindErrorA -< handleMultipleFunctions qf funcDefs
                         (fi, dep) <- bindErrorA -< mkFunctionInfo source qf systemDefined config rawfi
                         recordDependencies -< (metadataObject, schemaObject, [dep])
                         returnA -< fi)
                    |) addFunctionContext)
                  |) metadataObject) |)
        >-> (\infos -> M.catMaybes infos >- returnA)

      returnA -< SourceOutput tableCache functionCache sourceConfig

    buildAndCollectInfo
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
         , ArrowWriter (Seq CollectedInfo) arr, MonadIO m, MonadError QErr m, MonadUnique m, MonadReader BuildReason m
         , HasHttpManager m, HasSQLGenCtx m, HasDefaultSource m )
      => (Metadata, Inc.Dependency InvalidationKeys) `arr` BuildOutputs
    buildAndCollectInfo = proc (metadata, invalidationKeys) -> do
      let Metadata _ sources remoteSchemas collections allowlists
            customTypes actions cronTriggers = metadata

      -- remote schemas
      let remoteSchemaInvalidationKeys = Inc.selectD #_ikRemoteSchemas invalidationKeys
      remoteSchemaMap <- buildRemoteSchemas -< (remoteSchemaInvalidationKeys, (M.elems remoteSchemas))

      -- sources
      sourcesOutput <-
        (| Inc.keyed (\source sourceMetadata -> do
             let metadataObj = MetadataObject (MOSource source) $ toJSON source
             maybeResolvedSource <-
               (| withRecordInconsistency (liftEitherA <<< bindA -< resolveSource env sourceMetadata)
                |) metadataObj
             case maybeResolvedSource of
               Nothing -> returnA -< Nothing
               Just (ResolvedSource pgSourceConfig tablesMeta functionsMeta pgScalars) -> do
                 so <- buildSource -< ( sourceMetadata, pgSourceConfig, tablesMeta
                                      , functionsMeta, M.map fst remoteSchemaMap, invalidationKeys
                                      )
                 returnA -< Just (so, pgScalars))
         |) sources
        >-> (\infos -> M.catMaybes infos >- returnA)

      -- allow list
      let allowList = allowlists
            & HS.toList
            & map _crCollection
            & map (\cn -> maybe [] (_cdQueries . _ccDefinition) $ M.lookup cn collections)
            & concat
            & map (queryWithoutTypeNames . getGQLQuery . _lqQuery)
            & HS.fromList

      -- custom types
      let pgScalars = mconcat $ map snd $ M.elems sourcesOutput
          sourceTables = M.map (_soTables . fst) sourcesOutput
      maybeResolvedCustomTypes <-
        (| withRecordInconsistency
             (bindErrorA -< resolveCustomTypes sourceTables customTypes pgScalars)
         |) (MetadataObject MOCustomTypes $ toJSON customTypes)

      -- -- actions
      let actionList = M.elems actions
      (actionCache, annotatedCustomTypes) <- case maybeResolvedCustomTypes of
        Just resolvedCustomTypes -> do
          actionCache' <- buildActions -< ((resolvedCustomTypes, pgScalars), actionList)
          returnA -< (actionCache', resolvedCustomTypes)

        -- If the custom types themselves are inconsistent, we can’t really do
        -- anything with actions, so just mark them all inconsistent.
        Nothing -> do
          recordInconsistencies -< ( map mkActionMetadataObject actionList
                                   , "custom types are inconsistent" )
          returnA -< (M.empty, emptyAnnotatedCustomTypes)

      cronTriggersMap <- buildCronTriggers -< ((), M.elems cronTriggers)

      returnA -< BuildOutputs
        { _boSources = M.map fst sourcesOutput
        , _boActions = actionCache
        , _boRemoteSchemas = remoteSchemaMap
        , _boAllowlist = allowList
        , _boCustomTypes = annotatedCustomTypes
        , _boCronTriggers = cronTriggersMap
        }

    mkEventTriggerMetadataObject (source, _, table, eventTriggerConf) =
      let objectId = MOSourceObjId source $ SMOTableObj table $
                     MTOTrigger $ etcName eventTriggerConf
          definition = object ["table" .= table, "configuration" .= eventTriggerConf]
      in MetadataObject objectId definition

    mkCronTriggerMetadataObject catalogCronTrigger =
      let definition = toJSON catalogCronTrigger
      in MetadataObject (MOCronTrigger (ctName catalogCronTrigger))
                        definition

    mkActionMetadataObject (ActionMetadata name comment defn _) =
      MetadataObject (MOAction name) (toJSON $ CreateAction name defn comment)

    mkRemoteSchemaMetadataObject remoteSchema =
      MetadataObject (MORemoteSchema (_arsqName remoteSchema)) (toJSON remoteSchema)

    -- Given a map of table info, “folds in” another map of information, accumulating inconsistent
    -- metadata objects for any entries in the second map that don’t appear in the first map. This
    -- is used to “line up” the metadata for relationships, computed fields, permissions, etc. with
    -- the tracked table info.
    -- alignExtraTableInfo
    --   :: forall a b arr
    --    . (ArrowChoice arr, Inc.ArrowDistribute arr, ArrowWriter (Seq CollectedInfo) arr)
    --   => (b -> MetadataObject)
    --   -> ( M.HashMap QualifiedTable a
    --      , M.HashMap QualifiedTable [b]
    --      ) `arr` M.HashMap QualifiedTable (a, [b])
    -- alignExtraTableInfo mkMetadataObject = proc (baseInfo, extraInfo) -> do
    --   combinedInfo <-
    --     (| Inc.keyed (\tableName infos -> combine -< (tableName, infos))
    --     |) (align baseInfo extraInfo)
    --   returnA -< M.catMaybes combinedInfo
    --   where
    --     combine :: (QualifiedTable, These a [b]) `arr` Maybe (a, [b])
    --     combine = proc (tableName, infos) -> case infos of
    --       This  base        -> returnA -< Just (base, [])
    --       These base extras -> returnA -< Just (base, extras)
    --       That       extras -> do
    --         let errorMessage = "table " <> tableName <<> " does not exist"
    --         recordInconsistencies -< (map mkMetadataObject extras, errorMessage)
    --         returnA -< Nothing

    buildTableEventTriggers
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, ArrowWriter (Seq CollectedInfo) arr
         , Inc.ArrowCache m arr, MonadError QErr m, MonadIO m, MonadReader BuildReason m, HasSQLGenCtx m )
      => (SourceName, PGSourceConfig, TableCoreInfo, [EventTriggerConf]) `arr` EventTriggerInfoMap
    buildTableEventTriggers = proc (source, pgSourceConfig, tableInfo, eventTriggerConfs) ->
      buildInfoMap (etcName . (^. _4)) mkEventTriggerMetadataObject buildEventTrigger
        -< (tableInfo, map (source, pgSourceConfig, _tciName tableInfo,) eventTriggerConfs)
      where
        buildEventTrigger = proc (tableInfo, (source, sourceConfig, table, eventTriggerConf)) -> do
          let triggerName = etcName eventTriggerConf
              metadataObject = mkEventTriggerMetadataObject (source, sourceConfig, table, eventTriggerConf)
              schemaObjectId = SOSourceObj source $ SOITableObj table $ TOTrigger triggerName
              addTriggerContext e = "in event trigger " <> triggerName <<> ": " <> e
          (| withRecordInconsistency (
             (| modifyErrA (do
                  (info, dependencies) <- bindErrorA -< subTableP2Setup env source table eventTriggerConf
                  let tableColumns = M.mapMaybe (^? _FIColumn) (_tciFieldInfoMap tableInfo)
                  recreateViewIfNeeded -< (table, tableColumns, triggerName, etcDefinition eventTriggerConf, sourceConfig)
                  recordDependencies -< (metadataObject, schemaObjectId, dependencies)
                  returnA -< info)
             |) (addTableContext table . addTriggerContext))
           |) metadataObject

        recreateViewIfNeeded = Inc.cache $
          arrM \(tableName, tableColumns, triggerName, triggerDefinition, sourceConfig) -> do
            buildReason <- ask
            sqlGenCtx <- askSQLGenCtx
            when (buildReason == CatalogUpdate) $ do
              eitherResult <- runPgSourceWriteTx sourceConfig $ do
                delTriggerQ triggerName -- executes DROP IF EXISTS.. sql
                runHasSQLGenCtxT sqlGenCtx $
                  mkAllTriggersQ triggerName tableName (M.elems tableColumns) triggerDefinition
              liftEither eitherResult

    buildCronTriggers
      :: ( ArrowChoice arr
         , Inc.ArrowDistribute arr
         , ArrowWriter (Seq CollectedInfo) arr
         , Inc.ArrowCache m arr)
      => ((),[CronTriggerMetadata])
         `arr` HashMap TriggerName CronTriggerInfo
    buildCronTriggers = buildInfoMap ctName mkCronTriggerMetadataObject buildCronTrigger
      where
        buildCronTrigger = proc (_,cronTrigger) -> do
          let triggerName = triggerNameToTxt $ ctName cronTrigger
              addCronTriggerContext e = "in cron trigger " <> triggerName <> ": " <> e
          (| withRecordInconsistency (
            (| modifyErrA (liftEitherA <<< bindA -< runExceptT $ resolveCronTrigger env cronTrigger)
             |) addCronTriggerContext)
           |) (mkCronTriggerMetadataObject cronTrigger)

    buildActions
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, Inc.ArrowCache m arr
         , ArrowWriter (Seq CollectedInfo) arr)
      => ( (AnnotatedCustomTypes, HashSet PGScalarType)
         , [ActionMetadata]
         ) `arr` HashMap ActionName ActionInfo
    buildActions = buildInfoMap _amName mkActionMetadataObject buildAction
      where
        buildAction = proc ((resolvedCustomTypes, pgScalars), action) -> do
          let ActionMetadata name comment def actionPermissions = action
              addActionContext e = "in action " <> name <<> "; " <> e
          (| withRecordInconsistency (
             (| modifyErrA (do
                  (resolvedDef, outObject) <- liftEitherA <<< bindA -<
                    runExceptT $ resolveAction env resolvedCustomTypes def pgScalars
                  let permissionInfos =
                        map (uncurry ActionPermissionInfo . (_apmRole &&& _apmComment)) actionPermissions
                      permissionMap = mapFromL _apiRole permissionInfos
                  returnA -< ActionInfo name outObject resolvedDef permissionMap comment)
              |) addActionContext)
           |) (mkActionMetadataObject action)

    buildRemoteSchemas
      :: ( ArrowChoice arr, Inc.ArrowDistribute arr, ArrowWriter (Seq CollectedInfo) arr
         , Inc.ArrowCache m arr , MonadIO m, MonadUnique m, HasHttpManager m )
      => ( Inc.Dependency (HashMap RemoteSchemaName Inc.InvalidationKey)
         , [AddRemoteSchemaQuery]
         ) `arr` HashMap RemoteSchemaName (RemoteSchemaCtx, MetadataObject)
    buildRemoteSchemas =
      buildInfoMapPreservingMetadata _arsqName mkRemoteSchemaMetadataObject buildRemoteSchema
      where
        -- We want to cache this call because it fetches the remote schema over HTTP, and we don’t
        -- want to re-run that if the remote schema definition hasn’t changed.
        buildRemoteSchema = Inc.cache proc (invalidationKeys, remoteSchema) -> do
          Inc.dependOn -< Inc.selectKeyD (_arsqName remoteSchema) invalidationKeys
          (| withRecordInconsistency (liftEitherA <<< bindA -<
               runExceptT $ addRemoteSchemaP2Setup env remoteSchema)
           |) (mkRemoteSchemaMetadataObject remoteSchema)

-- | @'withMetadataCheck' cascade action@ runs @action@ and checks if the schema changed as a
-- result. If it did, it checks to ensure the changes do not violate any integrity constraints, and
-- if not, incorporates them into the schema cache.
withMetadataCheck
  :: (MonadTx m, CacheRWM m, HasSQLGenCtx m) => SourceName -> Bool -> m a -> m a
withMetadataCheck source cascade action = do
  -- Drop hdb_views so no interference is caused to the sql query
  liftTx $ Q.catchE defaultTxErrorHandler clearHdbViews
  sc <- askSchemaCache
  let sourceTables = maybe mempty _pcTables $ M.lookup source $ scPostgres sc
      existingFunctions = maybe mempty _pcFunctions $ M.lookup source $ scPostgres sc
      existingInconsistentObjs = scInconsistentObjs sc

  -- Get the metadata before the sql query, everything, need to filter this
  (oldTableMeta, oldFunctionMeta) <- fetchMeta sourceTables existingFunctions
  -- oldMetaU <- liftTx $ Q.catchE defaultTxErrorHandler fetchTableMeta
  -- oldFuncMetaU <- liftTx $ Q.catchE defaultTxErrorHandler fetchFunctionMeta

  -- Run the action
  res <- action

  -- Get the metadata after the sql query
  (newTableMeta, newFunctionMeta) <- fetchMeta sourceTables existingFunctions

  let existingTablesOldMeta = filter (flip M.member sourceTables . tmTable) oldTableMeta
      schemaDiff = getSchemaDiff existingTablesOldMeta newTableMeta
      FunctionDiff droppedFuncs alteredFuncs = getFuncDiff oldFunctionMeta newFunctionMeta
      overloadedFuncs = getOverloadedFuncs (M.keys existingFunctions) newFunctionMeta

  -- Old Code TODO: Clean up
  -- newMeta <- liftTx $ Q.catchE defaultTxErrorHandler fetchTableMeta
  -- newFuncMeta <- liftTx $ Q.catchE defaultTxErrorHandler fetchFunctionMeta
  -- sc <- askSchemaCache
  -- let existingInconsistentObjs = scInconsistentObjs sc
  --     sourceTables = maybe mempty _pcTables $ M.lookup source $ scPostgres sc
  --     sourceTableNames = M.keys sourceTables
  --     oldMeta = flip filter oldMetaU $ \tm -> tmTable tm `elem` sourceTableNames
  --     schemaDiff = getSchemaDiff oldMeta newMeta
  --     existingFuncs = M.keys $ maybe mempty _pcFunctions $ M.lookup source $ scPostgres sc
  --     oldFuncMeta = flip filter oldFuncMetaU $ \fm -> fmFunction fm `elem` existingFuncs
  --     FunctionDiff droppedFuncs alteredFuncs = getFuncDiff oldFuncMeta newFuncMeta
  --     overloadedFuncs = getOverloadedFuncs existingFuncs newFuncMeta

  -- Do not allow overloading functions
  unless (null overloadedFuncs) $
    throw400 NotSupported $ "the following tracked function(s) cannot be overloaded: "
    <> reportFuncs overloadedFuncs

  indirectDeps <- getSchemaChangeDeps source schemaDiff

  -- Report back with an error if cascade is not set
  when (indirectDeps /= [] && not cascade) $ reportDepsExt indirectDeps []

  metadataUpdater <- execWriterT $ do
    -- Purge all the indirect dependents from state
    mapM_ (purgeDependentObject >=> tell) indirectDeps

    -- Purge all dropped functions
    let purgedFuncs = flip mapMaybe indirectDeps $ \dep ->
          case dep of
            SOSourceObj _ (SOIFunction qf) -> Just qf
            _                              -> Nothing

    forM_ (droppedFuncs \\ purgedFuncs) $ \qf -> do
      tell $ dropFunctionInMetadata source qf

    -- Process altered functions
    forM_ alteredFuncs $ \(qf, newTy) -> do
      when (newTy == FTVOLATILE) $
        throw400 NotSupported $
        "type of function " <> qf <<> " is altered to \"VOLATILE\" which is not supported now"

    -- update the schema cache and hdb_catalog with the changes
    processSchemaChanges sourceTables schemaDiff

  buildSchemaCache metadataUpdater
  postSc <- askSchemaCache

  -- Recreate event triggers in hdb_views
  forM_ (M.elems sourceTables) $ \(TableInfo coreInfo _ eventTriggers) -> do
          let table = _tciName coreInfo
              columns = getCols $ _tciFieldInfoMap coreInfo
          forM_ (M.toList eventTriggers) $ \(triggerName, eti) -> do
            let opsDefinition = etiOpsDef eti
            mkAllTriggersQ triggerName table columns opsDefinition

  let currentInconsistentObjs = scInconsistentObjs postSc
  checkNewInconsistentMeta existingInconsistentObjs currentInconsistentObjs

  return res
  where
    reportFuncs = T.intercalate ", " . map dquoteTxt

    processSchemaChanges
      :: ( MonadError QErr m
         , CacheRM m
         , MonadWriter MetadataModifier m
         )
      => TableCache -> SchemaDiff -> m ()
    processSchemaChanges sourceTables schemaDiff = do
      -- Purge the dropped tables
      forM_ droppedTables $
        \tn -> tell $ MetadataModifier $ metaSources.ix source.smTables %~ M.delete tn

      for_ alteredTables $ \(oldQtn, tableDiff) -> do
        ti <- case M.lookup oldQtn sourceTables of
          Just ti -> return ti
          Nothing -> throw500 $ "old table metadata not found in cache : " <>> oldQtn
        processTableChanges source (_tiCoreInfo ti) tableDiff
      where
        SchemaDiff droppedTables alteredTables = schemaDiff

    checkNewInconsistentMeta
      :: (QErrM m)
      => [InconsistentMetadata] -> [InconsistentMetadata] -> m ()
    checkNewInconsistentMeta originalInconsMeta currentInconsMeta =
      unless (null newInconsistentObjects) $
        throwError (err500 Unexpected "cannot continue due to newly found inconsistent metadata")
          { qeInternal = Just $ toJSON newInconsistentObjects }
      where
        diffInconsistentObjects = M.difference `on` groupInconsistentMetadataById
        newInconsistentObjects = nub $ concatMap toList $
          M.elems (currentInconsMeta `diffInconsistentObjects` originalInconsMeta)

{- Note [Keep invalidation keys for inconsistent objects]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
After building the schema cache, we prune InvalidationKeys for objects
that no longer exist in the schema to avoid leaking memory for objects
that have been dropped. However, note that we *don’t* want to drop
keys for objects that are simply inconsistent!

Why? The object is still in the metadata, so next time we reload it,
we’ll reprocess that object. We want to reuse the cache if its
definition hasn’t changed, but if we dropped the invalidation key, it
will incorrectly be reprocessed (since the invalidation key changed
from present to absent). -}
