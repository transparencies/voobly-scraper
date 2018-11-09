{-# OPTIONS -fno-warn-deprecations #-}

module Data.Mgz.Simulate where

import RIO

import Data.Mgz.Deserialise
import Data.Mgz.Constants
import qualified RIO.List as L
import Data.List.NonEmpty(NonEmpty(..))
import qualified Data.List.NonEmpty as NE
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

  let initialMap = IxSet.fromList $ map (\t -> MapTile (tilePositionX t) (tilePositionY t) []) (headerTiles recInfoHeader)
      s0 = GameState IxSet.empty IxSet.empty initialMap (HM.fromList $ map (\i -> (PlayerId $ playerInfoNumber i, i)) (headerPlayers recInfoHeader))
      s1 = gameState $ execState (initialiseGameState recInfoHeader) (SimState 0 s0 HM.empty)

  logInfo "Building base events"

  let s2 = gameState $ execState (mapM buildBasicEvents recInfoOps) (SimState 0 s1 HM.empty)

  logInfo $ "Total events added: " <> displayShow (IxSet.size . events $ s2)

  logInfo "Making simple inferences"

  let s3 = gameState $ execState makeSimpleInferences (SimState 0 s2 HM.empty)

  logInfo "Linking build commands with buildings"
  let s4 = gameState $ execState (replicateM 3 linkBuildingsToCommands) (SimState 0 s3 HM.empty)

  pure $ s4


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
        let (toRe, rest) = L.splitAt (objectPartsNumber (normaliseObjectType $ objectRawUnitId x) - 1) xs
        in x : (map (\o -> o{objectRawUnitId = 999999}) toRe) ++ rest


buildBasicEvents :: Op -> Sim ()
buildBasicEvents (OpTypeSync OpSync{..}) = modify' (\ss -> ss{ticks = ticks ss + opSyncTime})
buildBasicEvents (OpTypeCommand cmd) = addCommandAsEvent cmd
buildBasicEvents _ = pure ()


-- at the moment we aren't placing wolves etc but we should!
handlePlayerObject :: ObjectRaw -> Sim ()
handlePlayerObject oRaw@ObjectRaw{..} = do
  let noType = normaliseObjectType objectRawUnitId
  case objectRawType of
    -- units
    70 -> do
      when (isResourceOrRelic noType) $ do
        let mObject = MapObject noType (PlayerId objectRawOwner) oRaw
        placeMapObject mObject objectRawPos
      let o = Object {
                  objectId = ObjectId objectRawObjectId
                , objectPlayer =  Just . PlayerId $ objectRawOwner
                , objectInfo = ObjectInfoUnit $ Unit {
                            unitType = objectTypeToUnitType noType
                          }
                , objectPlacedByGame = True
                         }
      void $ updateObject o

    80 -> do
      let o = Object {
                  objectId = ObjectId objectRawObjectId
                , objectPlayer = Just . PlayerId $ objectRawOwner
                , objectInfo = ObjectInfoBuilding $ Building {
                            buildingType = BuildingTypeKnown noType,
                            buildingPos = Just (objectRawPos),
                            buildingPlaceEvent = Nothing
                          }
                , objectPlacedByGame = True
                         }
      void $ updateObject o
    _ -> do
      let mObject = MapObject noType (PlayerId objectRawOwner) oRaw
      when (HM.member  noType objectTypeToResourceKindMap ) $ placeMapObject mObject objectRawPos
      let o = Object {
                  objectId = ObjectId objectRawObjectId
                , objectPlayer = Just . PlayerId $ objectRawOwner
                , objectInfo = ObjectInfoMapObject $ mObject
                , objectPlacedByGame = True
                }
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
    Just t ->
      case mapTileObjects t of
        [] -> do
          let newMap = IxSet.updateIx (mapTileCombinedIdx t) t{mapTileObjects = [mo]} mTiles
          modify' $ \ss ->
            let gs = gameState ss
            in ss{gameState = gs{mapTiles = newMap}}
        xs -> error $ "Overlap in map tile when trying to place " ++ show mo ++ " at " ++ show p ++ ": found " ++ show xs




makeSimpleInferences :: Sim ()
makeSimpleInferences = do
  unknownUnits <- fmap (IxSet.getEQ (Just UnitTypeUnknown)) $ getObjectSet
  void $ mapM inferUnitType $ IxSet.toList unknownUnits

  unknownBuildings <- fmap (IxSet.getEQ (Just BuildingTypeUnknown)) $ getObjectSet
  void $ mapM inferBuildingType $ IxSet.toList unknownBuildings

  unplayerEvents <- fmap (IxSet.getEQ (Nothing :: Maybe PlayerId)) $ getEventSet
  void $ mapM inferPlayerForEvent $ IxSet.toList unplayerEvents

  primaryEvents <- fmap (IxSet.getEQ EventTypeWPrimary) $ getEventSet
  void $ mapM inferDetailForEvent $ IxSet.toList primaryEvents



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

    inferUnitType :: Object -> Sim ()
    inferUnitType o = do
      villagerEvents <- fmap (ixsetGetIn [EventTypeWBuild]  . IxSet.getEQ (objectId o)) $ getEventSet
      if IxSet.size villagerEvents > 0
        then void $ updateObject o{objectInfo = ObjectInfoUnit $ Unit UnitTypeVillager}
        else do
          militaryEvents <- fmap (ixsetGetIn [EventTypeWPatrol, EventTypeWMilitaryDisposition, EventTypeWTargetedMilitaryOrder]  . IxSet.getEQ (objectId o)) $ getEventSet
          if IxSet.size militaryEvents > 0
            then void $ updateObject o{objectInfo = ObjectInfoUnit $ Unit (UnitTypeMilitary MilitaryTypeUnknown)}
            else pure ()

    inferBuildingType :: Object -> Sim ()
    inferBuildingType o = do
      techEvents <-  fmap (IxSet.toList . ixsetGetIn [EventTypeWResearch]  . IxSet.getEQ (objectId o)) $ getEventSet
      let researchedTechs = L.nub . catMaybes $ map eventTechType techEvents
          utsFromTechs = L.nub . concat . catMaybes $ map ((flip HM.lookup) techToBuildingMap) researchedTechs
      when (length utsFromTechs < 1 && length techEvents > 0) $ traceM $ "Could not find a building type that researches " <> displayShowT researchedTechs

      trainEvents <- fmap (IxSet.toList . ixsetGetIn [EventTypeWTrain]  . IxSet.getEQ (objectId o)) $ getEventSet
      let trainedUnitTypes = L.nub . concat . map NE.toList . catMaybes $ map eventTrainObjectType trainEvents
          utsFromTrainedUnits = L.nub . concat . catMaybes $ map ((flip HM.lookup) trainUnitToBuildingMap) trainedUnitTypes
      when (length utsFromTrainedUnits < 1 && length trainEvents > 0) $ traceM $ "Could not find a building type that trains " <> displayShowT trainedUnitTypes

      case L.nub $ concat [utsFromTechs, utsFromTrainedUnits] of
        [] -> pure ()
        [x] -> void $ updateObject o{objectInfo = ObjectInfoBuilding $ Building (BuildingTypeKnown x) (buildingObjectPos o) (buildingPlaceEvent . extractBuilding $ o)}
        x:xs -> void $ updateObject o{objectInfo = ObjectInfoBuilding $ Building (BuildingTypeOneOf $ x :| xs) (buildingObjectPos o) (buildingPlaceEvent . extractBuilding $ o)}

    inferDetailForEvent :: Event -> Sim ()
    inferDetailForEvent e@Event{..} = do
      mEt <-
        case eventType of
          EventTypePrimary EventPrimary{..} -> do
            target <- lookupObjectOrFail eventPrimaryTarget
            actors <- mapM lookupObjectOrFail eventPrimaryObjects
            tryWhileNothing $ map (\f -> f eventPlayerResponsible target actors eventPrimaryPos) [construeAsGather, construeAsAttack, construeAsRelicGather]
          _ -> pure Nothing
      case mEt of
            Nothing -> pure ()
            Just et -> void $ updateEvent (e{eventType = et})

    construeAsGather :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsGather pId t actors p =
      if and (map isObjectVillager actors) && isObjectResource t && (not $ isObjectEnemy pId t)
        then do
         pure . Just $ EventTypeGather EventGather{
            eventGatherTargetId = objectId t
          , eventGatherGatherers = map (unitId . asUnit) actors
          , eventGatherPos = p
          }
        else
          if and (map ((==) ObjectTypeWUnit . objectTypeW) actors) && isObjectResource t &&  (not $ isObjectEnemy pId t) && (not . isObjectPrimaryActableByPlayerMilitary pId $ t)
            then do
              actors' <- mapM (\o -> updateObject o{objectInfo = ObjectInfoUnit Unit{unitType = UnitTypeVillager}}) actors
              pure . Just $ EventTypeGather EventGather{
                    eventGatherTargetId = objectId t
                  , eventGatherGatherers = map (unitId . asUnit) actors'
                  , eventGatherPos = p
                }
            else pure Nothing
    construeAsAttack :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsAttack pId t actors p =
      if isObjectEnemy pId t
        then do
         void $ mapM convertObjectToAttackingBuildingType actors
         pure . Just $ EventTypeAttack EventAttack{
                eventAttackAttackers =  map objectId actors
              , eventAttackTargetId = objectId t
              , eventAttackPos = p
              }
        else pure Nothing
    construeAsRelicGather :: Maybe PlayerId -> Object -> [Object] -> Pos -> Sim (Maybe EventType)
    construeAsRelicGather _pId t actors p =
      if doesObjectMatch t isRelic -- the only people who can primary relics are monks
        then do
         actors' <- mapM ((flip convertObjectToKnownUnit) OT_Monk) actors
         pure . Just $ EventTypeGatherRelic EventGatherRelic{
                eventGatherRelicGatherers =  map (unitId . asUnit) actors'
              , eventGatherRelicTargetId = objectId t
              , eventGatherRelicPos = p
              }
        else pure Nothing


linkBuildingsToCommands :: Sim ()
linkBuildingsToCommands = do
  -- first we try to classify our totally unknown objects as units
  unknownObjects <- fmap (IxSet.toList .  IxSet.getEQ (ObjectTypeWUnknown)) $ getObjectSet
  void $ mapM tryBasicAssigning unknownObjects

  buildingsMissingInfo <- fmap (IxSet.toList .  IxSet.getEQ (ObjectTypeWBuilding) . IxSet.getEQ (ObjectPlacedByGameIdx False)) $ getObjectSet
  void $ mapM assignBasedOnBuildOrders $  filter (isNothing . buildingPlaceEvent . extractBuilding) buildingsMissingInfo

  makeSimpleInferences

  where
    tryBasicAssigning :: Object -> Sim ()
    tryBasicAssigning o@Object{..} =
      case objectInfo of
        ObjectInfoUnknown (Just t) ->
          case objectTypeToObjectTypeW t of
            ObjectTypeWBuilding -> void $ updateObject $ o{objectInfo = ObjectInfoBuilding Building{buildingType = BuildingTypeKnown t, buildingPos = Nothing, buildingPlaceEvent = Nothing}}
            ObjectTypeWUnit -> void $ updateObject $ o{objectInfo = ObjectInfoUnit Unit{unitType = objectTypeToUnitType t}}
            ObjectTypeWMapObject -> error "A new map object appeared? How???"
            -- if it is unknown then, well, no change
            _ -> pure ()
        _ -> pure ()
    assignBasedOnBuildOrders :: Object -> Sim ()
    assignBasedOnBuildOrders o@Object{..} = do
      case objectInfo of
        ObjectInfoBuilding b -> do
          preEvents <- findEventsRangeForObjectCreation objectId (fmap nonEmptySingle $ toObjectType o)
          let buildEvents = filter (isNothing . eventBuildBuilding . extractEventBuild  ) $ IxSet.toList $ (IxSet.getEQ EventTypeWBuild) preEvents
              restrictByPlayer =
                case objectPlayer of
                  Nothing -> buildEvents
                  Just pid -> filter (\e -> eventPlayerResponsible e == Just pid) buildEvents
              restrictByType =
                case toObjectType b of
                  Nothing -> restrictByPlayer
                  Just bts -> filter (\e -> eventBuildBuildingObjectType e `elem` (NE.toList bts)) restrictByPlayer

          foundE <- case restrictByType of
                     [] -> do
                      traceShowM $ o
                      mapM debugBuildEvent $ buildEvents
                      traceM $ "Impossible - this building was never placed?"
                      error ""
                     [x] -> do
                      pure $ Just x
                     _xs -> do
                      traceM $ "\n\n"
                      traceShowM $ o
                      mapM debugBuildEvent $ _xs
                      error ""
                      pure Nothing




          case foundE of
            Nothing -> do
             -- we can't find the specific event, but maybe we can assign some info
             let possiblePlayers = L.nub . catMaybes $ map eventPlayerResponsible restrictByType
                 possibleTypes = L.nub $ map eventBuildBuildingObjectType restrictByType
             case (possiblePlayers, possibleTypes) of
               ([p], [ot]) -> do
                -- for now consume the earlier one though this might be an issue later!
                --linkBuildingToEvent o $ L.Partial.head restrictByType
                o' <- assignPlayerToObject o p
                void $ updateObject $ setObjectType o' ot
                --traceShowM $ o
                --void $ mapM debugBuildEvent $ restrictByType
               (ps, pts) -> do
                 case ps of
                  [p] -> void $ assignPlayerToObject o p
                  _ -> do
                    --traceShowM $ o
                    --void $ mapM debugBuildEvent $ take 2 xs
                    pure ()
                 case pts of
                  [ot] -> do
                    void $ updateObject $ setObjectType o ot
                  _ -> do
                    let oBuilding = extractBuilding o
                    case buildingType oBuilding of
                      BuildingTypeUnknown -> do
                        void $ updateObject $ o{objectInfo = ObjectInfoBuilding oBuilding{buildingType = BuildingTypeOneOf $ nonEmptyPartial possibleTypes}}
                      BuildingTypeKnown _ -> pure ()
                      BuildingTypeOneOf ne -> do
                        let newnon = L.intersect (NE.toList ne) pts
                        void $ updateObject $ o{objectInfo = ObjectInfoBuilding oBuilding{buildingType = BuildingTypeOneOf $ nonEmptyPartial newnon}}
            -- there is only one possible build event - we can link these together
            Just e ->
              linkBuildingToEvent o e
        _ -> pure ()

    linkBuildingToEvent :: Object -> Event -> Sim ()
    linkBuildingToEvent o e = do
      let eBuild = extractEventBuild e
          oBuilding = extractBuilding o
      o' <- updateObject $ setObjectType o $ eventBuildBuildingObjectType e
      o'' <- case eventPlayerResponsible e of
               Just p -> assignPlayerToObject o' p
               Nothing -> pure o'

      void $ updateEvent $ e{eventType = EventTypeBuild eBuild{eventBuildBuilding = Just (buildingId . asBuilding $ o)}}
      void $ updateObject $ o''{objectInfo = ObjectInfoBuilding oBuilding{buildingPlaceEvent = Just (eventId e)}}
      pure ()
    debugBuildEvent :: Event -> Sim ()
    debugBuildEvent e = do
      tl <- renderEvent e
      traceM $ TL.toStrict $ TL.toLazyText tl













