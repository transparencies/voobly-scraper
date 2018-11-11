{-# OPTIONS -fno-warn-deprecations #-}

module Data.Mgz.Simulate where

import RIO

import Data.Mgz.Deserialise
import Data.Mgz.Constants
import qualified RIO.List as L
--import qualified Data.List.NonEmpty as NE
import qualified Data.IxSet.Typed as IxSet
import Control.Monad.State.Strict
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Text.Lazy as TL
import qualified RIO.HashMap as HM


import Data.Mgz.Simulate.Objects
import Data.Mgz.Simulate.State
import Data.Mgz.Simulate.Events
import Data.Mgz.Simulate.Render
import Data.Mgz.Simulate.Command
import Data.Mgz.Utils



replay :: HasLogFunc env => GameState -> RIO env ()
replay gs = do
  logInfo "Rendering to file"
  let r = evalState renderEvents (SimState 0 gs HM.empty)
  liftIO $ TL.writeFile "/code/voobly-scraper/simHistory" $  r
  let r2 = evalState renderAllObjects (SimState 0 gs HM.empty)
  liftIO $ TL.writeFile "/code/voobly-scraper/simObjects" $  r2
  logInfo "Render done"


simulate :: HasLogFunc env => RecInfo -> RIO env GameState
simulate RecInfo{..} = do
  logInfo "Start simulating"
  logInfo "Recreating initial game state"

  let
      s0 = emptyGameState recInfoHeader
      s1 = gameState $ execState (initialiseGameState recInfoHeader) (SimState 0 s0 HM.empty)

  logInfo "Building base events"

  let s2 = gameState $ execState (mapM buildBasicEvents recInfoOps) (SimState 0 s1 HM.empty)
  logInfo $ "Total events added: " <> displayShow (IxSet.size . events $ s2)

  logInfo "Making simple inferences"

  let s3 = gameState $ execState makeSimpleInferences (SimState 0 s2 HM.empty)


  logInfo "Linking build commands with buildings"
  let s4 = gameState $ execState (replicateM 3 linkBuildingsToCommands) (SimState 0 s3 HM.empty)

  logInfo "Linking train commands with units"
  let s5 = gameState $ execState (replicateM 3 (linkUnitsToTrainCommands False)) (SimState 0 s4 HM.empty)

  let s6 = gameState $ execState ((linkUnitsToTrainCommands True)) (SimState 0 s5 HM.empty)

  pure $ s6


initialiseGameState :: Header -> Sim ()
initialiseGameState h = do
  void $ (flip mapM) (headerPlayers h) $ \PlayerInfo{..} -> do
    mapM handlePlayerObject $ reclassifyExtraneousObjectParts playerInfoObjects
    where
      -- we are reassigning these for now
      reclassifyExtraneousObjectParts :: [ObjectRaw] -> [ObjectRaw]
      reclassifyExtraneousObjectParts [] = []
      reclassifyExtraneousObjectParts [x] = [x]
      reclassifyExtraneousObjectParts ((!x):(!xs)) =
        let (toRe, rest) = L.splitAt (objectPartsNumber (objectRawUnitId x) - 1) xs
        in x : (map (\o -> o{objectRawUnitId = OT_ExtraneousPart (objectRawUnitId o)}) toRe) ++ rest


buildBasicEvents :: Op -> Sim ()
buildBasicEvents (OpTypeSync OpSync{..}) = modify' (\ss -> ss{ticks = ticks ss + opSyncTime})
buildBasicEvents (OpTypeCommand cmd) = handleCommand cmd
buildBasicEvents _ = pure ()

handlePlayerObject :: ObjectRaw -> Sim ()
handlePlayerObject oRaw@ObjectRaw{..} = do
  let (o, mObject) = objectFromObjectRaw oRaw
  placeMapObject mObject objectRawPos
  void $ updateObject o
    where
      --debugObjectRaw :: Sim ()
      --debugObjectRaw = traceM $ displayShowT objectRawObjectId <> " " <> displayShowT objectRawOwner  <> " " <> (displayShowT $ normaliseObjectType objectRawUnitId) <> " at " <> displayShowT objectRawPos

placeMapObject :: MapObject -> Pos -> Sim ()
placeMapObject mo p = do
  mTiles <- fmap (mapTiles . gameState) get
  let mTile = IxSet.getOne $ IxSet.getEQ (posToCombinedIdx p) mTiles
  case mTile of
    Nothing -> error $ "Could not find map tile at " ++ show p ++ " for object " ++ show mo
    Just t -> do
      let newOs = mapTileObjects t ++ [mo]
      if length (filter (not . canOverlap) newOs) < 2
        then do
          let newMap = IxSet.updateIx (mapTileCombinedIdx t) t{mapTileObjects = newOs} mTiles
          modify' $ \ss ->
            let gs = gameState ss
            in ss{gameState = gs{mapTiles = newMap}}
        else  error $ "Overlap in map tile when trying to place " ++ show mo ++ " at " ++ show p ++ ": found " ++ show (mapTileObjects t)
    where
      canOverlap :: MapObject -> Bool
      canOverlap = canObjectTypeOverlap . objectRawUnitId . mapObjectOriginal



makeSimpleInferences :: Sim ()
makeSimpleInferences = do
  unknownUnits <- fmap (IxSet.getLT OTRestrictionIsMilitaryUnit . IxSet.getEQ ObjectTypeWUnit) $ getObjectSet
  void $ mapM inferUnitType $ IxSet.toList unknownUnits

  unknownBuildings <- fmap (IxSet.getGT OTRestrictWKnown . IxSet.getEQ ObjectTypeWBuilding) $ getObjectSet
  void $ mapM inferBuildingType $ IxSet.toList unknownBuildings

  unplayerEvents <- fmap (IxSet.getEQ (Nothing :: Maybe PlayerId)) $ getEventSet
  void $ mapM inferPlayerForEvent $ IxSet.toList unplayerEvents

  eventsWithPlayer <- fmap (IxSet.getGT (Nothing :: Maybe PlayerId)) $ getEventSet
  void $ mapM inferPlayerForObjects $ IxSet.toList eventsWithPlayer


  primaryEvents <- fmap (IxSet.getEQ EventTypeWPrimary) $ getEventSet
  void $ mapM inferDetailForEvent $ IxSet.toList primaryEvents

  garrisonAndRepairEvents <- fmap (ixsetGetIn [EventTypeWRepair, EventTypeWGarrison, EventTypeWUngarrison]) $ getEventSet
  void $ mapM inferPlayerEtcForRepairGarrison $ IxSet.toList garrisonAndRepairEvents

-- , OTRestrictionIsGarrisonable, OTRestrictionIsUngarrisonable

  unknownRepairables <- fmap (ixsetGetIn [OTRestrictionIsRepairable] . IxSet.getEQ ObjectTypeWUnknown) $ getObjectSet
  void $ mapM inferIsRepairableBuilding $ IxSet.toList unknownRepairables

  pure ()
  where
    inferPlayerForEvent :: Event -> Sim ()
    inferPlayerForEvent e = do
      objs <- fmap catMaybes $  mapM lookupObject $ eventActingObjectsIdx e
      let ps = L.nub . catMaybes $ map objectPlayer objs
      case ps of
        [] -> pure ()
        [x] -> void $ updateEvent e{eventPlayerResponsible = Just x}
        xs -> error $ "Multiple player owners for units in single event" ++ show xs

    inferPlayerForObjects :: Event -> Sim ()
    inferPlayerForObjects e@Event{..} = do
      case eventPlayerResponsible of
        Nothing -> pure ()
        Just pid -> do
          objs <- fmap catMaybes $  mapM lookupObject $ eventActingObjectsIdx e
          void $ mapM ((flip updateObjectWithPlayerIfNone) pid) objs
    inferPlayerEtcForRepairGarrison :: Event -> Sim ()
    inferPlayerEtcForRepairGarrison Event{..} =
      case eventType of
        EventTypeRepair EventRepair{..} -> do
          o <- lookupObjectOrFail eventRepairRepaired
          o' <- updateWithRestriction o OTRestrictionIsRepairable
          void $ updateObjectWithMaybePlayerIfNone o' eventPlayerResponsible
        EventTypeGarrison EventGarrison{..} -> do
          o <- lookupObjectOrFail eventGarrisonTargetId
          o' <- updateWithRestriction o OTRestrictionIsGarrisonable
          void $ updateObjectWithMaybePlayerIfNone o' eventPlayerResponsible
        EventTypeUngarrison EventUngarrison{..} -> do
          os <- mapM lookupObjectOrFail eventUngarrisonReleasedFrom
          void $ (flip mapM) os $ \o -> do
            o' <- updateWithRestriction o OTRestrictionIsUngarrisonable
            updateObjectWithMaybePlayerIfNone o' eventPlayerResponsible

        _ -> pure ()

    inferUnitType :: Object -> Sim ()
    inferUnitType o = do
      villagerEvents <- fmap (ixsetGetIn [EventTypeWBuild, EventTypeWRepair]  . IxSet.getEQ (objectId o)) $ getEventSet
      if IxSet.size villagerEvents > 0
        then void $ updateWithObjectType o OT_Villager
        else do
          militaryEvents <- fmap (ixsetGetIn [EventTypeWPatrol, EventTypeWMilitaryDisposition, EventTypeWTargetedMilitaryOrder]  . IxSet.getEQ (objectId o)) $ getEventSet
          if IxSet.size militaryEvents > 0
            then void $ updateWithRestriction o OTRestrictionIsMilitaryUnit
            else pure ()

    inferBuildingType :: Object -> Sim ()
    inferBuildingType o = do
      techEvents <-  fmap (IxSet.toList . ixsetGetIn [EventTypeWResearch]  . IxSet.getEQ (objectId o)) $ getEventSet
      let researchedTechs = L.nub . catMaybes $ map eventTechType techEvents
          utsFromTechs = L.nub . concat . catMaybes $ map ((flip HM.lookup) techToBuildingMap) researchedTechs
      when (length utsFromTechs < 1 && length techEvents > 0) $ traceM $ "Could not find a building type that researches " <> displayShowT researchedTechs

      trainEvents <- fmap (IxSet.toList . ixsetGetIn [EventTypeWTrain]  . IxSet.getEQ (objectId o)) $ getEventSet
      let trainedUnitTypes = L.nub . catMaybes $ map eventTrainObjectType trainEvents
          utsFromTrainedUnits = L.nub . concat . catMaybes $ map ((flip HM.lookup) trainUnitToBuildingMap) trainedUnitTypes
      when (length utsFromTrainedUnits < 1 && length trainEvents > 0) $ traceM $ "Could not find a building type that trains " <> displayShowT trainedUnitTypes

      case L.nub $ concat [utsFromTechs, utsFromTrainedUnits] of
        [] -> pure ()
        [x] -> void $ updateWithObjectType o x
        xs -> void $ updateWithObjectTypes o $ nonEmptyPartial xs

    inferIsRepairableBuilding :: Object -> Sim ()
    inferIsRepairableBuilding o = do
      allEventsPrior <- eventsPriorToObjectCreation o
      let eventsToLookAt = case objectPlayer o of
                            Nothing -> allEventsPrior
                            Just pid -> IxSet.getEQ (Just pid) allEventsPrior
      -- there were no train events that could have created this repairable so it must be a building
      if IxSet.null $ ixsetGetIn (map (Just . EventTrainedObjectTypeIdx) repairableUnits) eventsToLookAt
        then void $ updateWithRestriction o OTRestrictionIsBuilding
        else pure ()

    inferDetailForEvent :: Event -> Sim ()
    inferDetailForEvent e@Event{..} = do
      mEt <-
        case eventType of
          EventTypePrimary EventPrimary{..} -> do
            target <- lookupObjectOrFail eventPrimaryTarget
            actors <- mapM lookupObjectOrFail eventPrimaryObjects
            tryWhileNothing $ map (\f -> f eventPlayerResponsible target actors eventPrimaryPos) [construeAsGather, construeAsAttack, construeAsRelicGather, construeAsVillOnRepairable]
          _ -> pure Nothing
      case mEt of
            Nothing -> pure ()
            Just et -> void $ updateEvent (e{eventType = et})

    construeAsGather :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsGather pId t actors p =
       -- herdables can show up in these events
      if and (map isVillager $ filter (not . isHerdable) actors) && isResource t && (not $ isObjectEnemy pId t)
        then do
         pure . Just $ EventTypeGather EventGather{
            eventGatherTargetId = objectId t
          , eventGatherGatherers = map (unitId . asUnit) actors
          , eventGatherPos = p
          }
        else
          if and (map ((==) ObjectTypeWUnit . objectTypeW) actors) && isResource t &&  (not $ isObjectEnemy pId t) && (anyMeetsRestriction t OTRestrictionIsNotActableByMilitary)
            then do
              actors' <- mapM (\o -> updateObject $  restrictObjectType o OTRestrictionIsLandResourceGatherer) actors
              pure . Just $ EventTypeGather EventGather{
                    eventGatherTargetId = objectId t
                  , eventGatherGatherers = map (unitId . asUnit) actors'
                  , eventGatherPos = p
                }
            else pure Nothing

    construeAsVillOnRepairable :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsVillOnRepairable pId origT actors p =
      if and (map isVillager actors) && (isObjectFriend pId origT) && (not $ isResource origT)
        then do
          -- vills can only primary act on owned objects if they are reppairables
          t <- if isBuilding origT then pure origT else updateWithRestriction origT OTRestrictionIsRepairable
          let ts =
                if isBuilding t
                  then [EventTypeWRepair, EventTypeWBuild] ++ if isNotDropoffBuilding t then [] else [EventTypeWDropoff]
                  else if isUnit t
                         then [EventTypeWRepair]
                         else [EventTypeWRepair, EventTypeWBuild, EventTypeWDropoff]

          pure . Just $ EventTypeVillOnRepairable EventVillOnRepairable{
            eventVillOnRepairableType = nonEmptyPartial ts
          , eventVillOnRepairableObject = objectId t
          , eventVillOnRepairableVills = map (unitId . asUnit) actors
          , eventVillOnRepairablePos = p
          }
        else pure Nothing




    construeAsAttack :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsAttack pId t actors p =
      if isObjectEnemy pId t -- this doesn't take into account trade carts/cogs going to enemy markets/docks
        then do
         void $ (flip mapM) actors $ \b -> updateWithRestriction b OTRestrictionCanAttack

         pure . Just $ EventTypeAttack EventAttack{
                eventAttackAttackers =  map objectId actors
              , eventAttackTargetId = objectId t
              , eventAttackPos = p
              }
        else
          case pId of
            Just thisPlayer ->
              --if military units primary something unknown then it must belong to the enemy
              if or (map (\a -> isMilitaryUnit a && (not $ isMonk a)) actors) && objectPlayer t == Nothing
                then do
                  let otherPlayer = if thisPlayer == PlayerId 1 then PlayerId 2 else PlayerId 1 -- @team
                  void $ updateObjectWithPlayerIfNone t otherPlayer
                  pure Nothing
                else pure Nothing
            _ -> pure Nothing

    construeAsRelicGather :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsRelicGather _pId t actors p =
      if getObjectType t == Just OT_Relic -- the only people who can primary relics are monks
        then do
         actors' <- mapM ((flip updateWithObjectType) OT_Monk) actors
         pure . Just $ EventTypeGatherRelic EventGatherRelic{
                eventGatherRelicGatherers =  map (unitId . asUnit) actors'
              , eventGatherRelicTargetId = objectId t
              , eventGatherRelicPos = p
              }
        else pure Nothing



linkBuildingsBasedOnPosition :: Sim ()
linkBuildingsBasedOnPosition = do
  unknownObjects <- fmap (IxSet.toList .  IxSet.getEQ (ObjectTypeWUnknown) . IxSet.getEQ (ObjectPlacedByGameIdx False)) $ getObjectSet
  void $ mapM assignBasedOnPosition unknownObjects
  remainingUnknownObjects <- fmap (IxSet.toList .  IxSet.getEQ (ObjectTypeWUnknown) . IxSet.getEQ (ObjectPlacedByGameIdx False)) $ getObjectSet
  void  $ (flip mapM) remainingUnknownObjects $ \o -> do
    case objectPosHistory o of
      [] -> pure ()
      _ -> do
        possibleEvents <- fmap (\es -> filter (\e -> eventTypeW e == EventTypeWWall) es) $ findUnconsumedBuildOrWallEventsForObject o
        if null possibleEvents
          then void $ updateWithRestriction o OTRestrictionIsUnit -- if it wasn't placed as a building, and it has a position, then it must be a unit... or a wall...
          else pure ()
  where
    assignBasedOnPosition :: Object -> Sim ()
    assignBasedOnPosition o = do
      possibleEvents <- fmap (\es -> filter (\e -> eventTypeW e == EventTypeWBuild) es) $ findUnconsumedBuildOrWallEventsForObject o

      case filter (\e -> (not . null $ objectPosHistory o) && and (map  (\p -> p == getEventBuildPos e)  $ objectPosHistory o))  possibleEvents of
        [] -> pure ()
        [e] -> linkBuildingToEvent o e
        es -> do
          void $ mapM debugBuildEvent es



linkBuildingsToCommands :: Sim ()
linkBuildingsToCommands = do

  linkBuildingsBasedOnPosition
  buildingsMissingInfo <- fmap (IxSet.toList .  IxSet.getEQ (ObjectTypeWBuilding) . IxSet.getEQ (ObjectPlacedByGameIdx False)) $ getObjectSet
  void $ mapM assignBasedOnBuildOrders $  filter (isNothing . getBuildingPlaceEvent) buildingsMissingInfo

  makeSimpleInferences

  where
    assignBasedOnBuildOrders :: Object -> Sim ()
    assignBasedOnBuildOrders o = do
      possibleEvents <- findUnconsumedBuildOrWallEventsForObject o
      foundE <- case possibleEvents of
         [] -> do
            traceM $ "\n\nImpossible - this building was never placed?"
            traceShowM $ o
            allBuildEventsPrior <- fmap (IxSet.toList . IxSet.getEQ EventTypeWBuild) $  findEventsRangeForObjectCreation o Nothing
            void $ mapM debugBuildEvent $ allBuildEventsPrior
            pure Nothing
         [x] -> pure . Just $ x
         _ -> pure Nothing
      case foundE of
        Nothing -> do
         -- we can't find the specific event, but maybe we can assign some info
         let possiblePlayers = L.nub . catMaybes $ map eventPlayerResponsible possibleEvents
             possibleTypes = L.nub $ map eventBuildBuildingObjectType possibleEvents

         o' <- case possiblePlayers of
                 [p] -> updateObjectWithPlayerIfNone o p
                 _ -> pure o

         case possibleTypes of
           [] -> traceM $ "No possible types found!"
           [ot] -> void $ updateObject $ setObjectType o' ot
           _ -> void $ updateWithObjectTypes o' (nonEmptyPartial possibleTypes)

         case (possiblePlayers, possibleTypes, possibleEvents) of
            ([pid], [_], e1:[e2]) -> do -- all the same player and type and exactly two events
              deleteEvents <- fmap (IxSet.toList . IxSet.getEQ EventTypeWDelete . IxSet.getEQ (Just pid)) $ eventsPriorToObjectCreation o
              case filter (\e -> eventId e > eventId e1 && eventId e < eventId e2) deleteEvents of
                [del] -> do
                  -- link the del event object with the first event
                  deletedObj <- lookupObjectOrFail $ getEventDeleteObjectId del
                  if isBuilding deletedObj || objectTypeW deletedObj == ObjectTypeWUnknown
                    then do
                      linkBuildingToEvent deletedObj e1
                      linkBuildingToEvent o e2
                    else pure ()

                [] -> -- there are no relevant delete events - we know that this building definitely came from one of these orders so we will pick the first one (in cases where buildings were destroyed this might be wrong)
                  linkBuildingToEvent o e1
                _ ->  pure () -- for now we won't do anything with this - with map info we could be sure at this point so we'll leave it for now
            _ -> pure ()
              -- same - map info would probably get most of the rest of these - we can also compare timing if there are exactly two events for two players or whatever
             -- traceM "\n\n"
             -- traceShowM o
             -- void $ mapM debugBuildEvent $ possibleEvents



        Just e ->
        -- there is only one possible build event - we can link these together
          linkBuildingToEvent o e

linkBuildingToEvent :: Object -> Event -> Sim ()
linkBuildingToEvent o e = do
  o' <- updateObject $ setObjectType o $ eventBuildBuildingObjectType e
  o'' <- case eventPlayerResponsible e of
           Just p -> updateObjectWithPlayerIfNone o' p
           Nothing -> pure o'

  void $ updateEvent $ setEventLinkedBuilding e (buildingId . asBuilding $ o'')
  void $ updateObject $ setBuildingPlaceEvent o'' $ Just (eventId e)
  pure ()


debugBuildEvent :: Event -> Sim ()
debugBuildEvent e = do
  tl <- renderEvent e
  traceM $ TL.toStrict $ TL.toLazyText tl













linkUnitsToTrainCommands :: Bool -> Sim ()
linkUnitsToTrainCommands consumeEvents = do
  unitsMissingInfo <- fmap (IxSet.toList .  IxSet.getEQ (ObjectTypeWUnit) . IxSet.getEQ (ObjectPlacedByGameIdx False)) $ getObjectSet
  void $ mapM assignBasedOnTrainOrders $  filter (isNothing . getUnitTrainEvent) unitsMissingInfo
  makeSimpleInferences
  where
    assignBasedOnTrainOrders :: Object -> Sim ()
    assignBasedOnTrainOrders o = do
      possibleEvents <- findUnconsumedTrainEventsForObject o
      foundE <- case possibleEvents of
         [] -> do
            traceM $ "\n\nImpossible - this unit was never trained?"
            traceShowM $ o
            allTrainEventsPrior <- fmap (IxSet.toList . IxSet.getEQ EventTypeWTrain) $  findEventsRangeForObjectCreation o Nothing
            void $ mapM debugBuildEvent $ allTrainEventsPrior
            pure Nothing
         [x] -> pure . Just $ x
         _ -> pure Nothing
      case foundE of
        Nothing -> do
          case (consumeEvents, possibleEvents) of
            (True, (e:_)) -> do
              -- we are just consuming the earliest matching event
              o' <- if (isNothing $ getObjectType o)
                then updateObject $ setObjectTypes o $ nonEmptyPartial $ L.nub $ map eventTrainUnitObjectType possibleEvents
                else pure $ o

              void $ updateEvent $ setEventConsumedWithUnit e (unitId . asUnit $ o')
              --void $ updateObject $ setUnitTrainEvent o'' $ Just (eventId e)

            (_, _) -> do
               -- we can't find the specific event, but maybe we can assign some info
               let possiblePlayers = L.nub . catMaybes $ map eventPlayerResponsible possibleEvents
                   possibleTypes = L.nub $ map eventTrainUnitObjectType possibleEvents

               o' <- case possiblePlayers of
                       [p] -> updateObjectWithPlayerIfNone o p
                       _ -> pure o

               case possibleTypes of
                 [] -> traceM $ "No possible types found!"
                 [ot] -> void $ updateObject $ setObjectType o' ot
                 _ -> void $ updateWithObjectTypes o' (nonEmptyPartial possibleTypes)
        Just e ->
        -- there is only one possible train event - we can link these together
          linkUnitToEvent o e

    linkUnitToEvent :: Object -> Event -> Sim ()
    linkUnitToEvent o e = do
      o' <- updateObject $ setObjectType o $ eventTrainUnitObjectType e
      o'' <- case eventPlayerResponsible e of
               Just p -> updateObjectWithPlayerIfNone o' p
               Nothing -> pure o'

      void $ updateEvent $ setEventLinkedUnit e (unitId . asUnit $ o'')
      void $ updateObject $ setUnitTrainEvent o'' $ Just (eventId e)
      pure ()

