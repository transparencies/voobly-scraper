{-# OPTIONS -fno-warn-deprecations #-}
module Data.Mgz.Simulate.Command where
import RIO

import Data.Mgz.Utils
import Data.Mgz.Deserialise
import Data.Mgz.Constants
import Data.Mgz.Simulate.Objects
import Data.Mgz.Simulate.State
import Data.Mgz.Simulate.Events



handleCommand :: Command -> Sim ()
handleCommand c = do
  mEt <- runCommand c
  case mEt of
    Nothing -> pure ()
    Just et -> addRealEvent c (commandPlayerId c) et

class RunCommand a where
  runCommand :: a -> Sim (Maybe EventType)

instance RunCommand Command where
  runCommand (CommandTypePrimary c) = runCommand c
  runCommand (CommandTypeMove c) = runCommand c
  runCommand (CommandTypeStance c) = runCommand c
  runCommand (CommandTypeGuard c) = runCommand c
  runCommand (CommandTypeFollow c) = runCommand c
  runCommand (CommandTypePatrol c) = runCommand c
  runCommand (CommandTypeFormation c) = runCommand c
  runCommand (CommandTypeResearch c) = runCommand c
  runCommand (CommandTypeBuild c) = runCommand c
  runCommand (CommandTypeTrain c) = runCommand c
  runCommand (CommandTypeWaypoint c) = runCommand c
  runCommand (CommandTypeStop c) = runCommand c
  runCommand (CommandTypeRally c) = runCommand c
  runCommand (CommandTypeDelete c) = runCommand c
  runCommand (CommandTypeWall c) = runCommand c
  runCommand (CommandTypeResign c) = runCommand c
  runCommand (CommandTypeAttackGround c) = runCommand c
  runCommand (CommandTypeTribute c) = runCommand c
  runCommand (CommandTypeRepair c) = runCommand c
  runCommand (CommandTypeUngarrison c) = runCommand c
  runCommand (CommandTypeToggleGate c) = runCommand c
  runCommand (CommandTypeGarrison c) = runCommand c
  runCommand (CommandTypeSell c) = runCommand c
  runCommand (CommandTypeBuy c) = runCommand c
  runCommand (CommandTypeDropRelic c) = runCommand c
  runCommand (CommandTypeTownBell c) = runCommand c
  runCommand (CommandTypeBackToWork c) = runCommand c
  runCommand (CommandUnparsed _ _) = pure Nothing

commandPlayerId :: Command -> Maybe PlayerId
commandPlayerId (CommandTypePrimary CommandPrimary{..}) = Just commandPrimaryPlayerId
commandPlayerId (CommandTypeMove CommandMove{..}) = Just commandMovePlayerId
commandPlayerId (CommandTypeFormation CommandFormation{..}) = Just commandFormationPlayerId
commandPlayerId (CommandTypeResearch CommandResearch{..}) = Just commandResearchPlayerId
commandPlayerId (CommandTypeBuild CommandBuild{..}) = Just commandBuildPlayerId
commandPlayerId (CommandTypeWall CommandWall{..}) = Just commandWallPlayerId
commandPlayerId (CommandTypeWaypoint CommandWaypoint{..}) = Just commandWaypointPlayerId
commandPlayerId (CommandTypeResign CommandResign{..}) = Just commandResignPlayerId
commandPlayerId (CommandTypeTribute CommandTribute{..}) = Just commandTributeFrom
commandPlayerId (CommandTypeSell CommandSell{..}) = Just commandSellPlayer
commandPlayerId (CommandTypeBuy CommandBuy{..}) = Just commandBuyPlayer
commandPlayerId (CommandTypeDelete CommandDelete{..}) = Just commandDeletePlayerId
commandPlayerId _ = Nothing

instance RunCommand CommandPrimary where
  runCommand CommandPrimary{..} = do
    case commandPrimaryTargetId of
      Just tid -> do
        target <- getObject tid
        uids <- getSelectedObjectIds commandPrimaryUnitIds commandPrimaryPlayerId
        objs <- getObjectsForPlayer uids commandPrimaryPlayerId
        pure . Just . EventTypePrimary $ EventPrimary {
            eventPrimaryObjects = map objectId objs
          , eventPrimaryTarget = objectId target
          , eventPrimaryPos = commandPrimaryPos
          }
      Nothing -> do
        uids <- getSelectedObjectIds commandPrimaryUnitIds commandPrimaryPlayerId
        units <- getUnitsForPlayer uids commandPrimaryPlayerId
        pure . Just. EventTypeMove $ EventMove {
            eventMoveUnits = map unitId units
            , eventMovePos = commandPrimaryPos
          }

instance RunCommand CommandMove where
  runCommand CommandMove{..} = do
    uids <- getSelectedObjectIds commandMoveUnitIds commandMovePlayerId
    units <- getUnitsForPlayer uids commandMovePlayerId
    pure . Just $ EventTypeMove $ EventMove {
        eventMoveUnits = map unitId units
      , eventMovePos = commandMovePos
      }

instance RunCommand CommandStance where
  runCommand CommandStance{..} = do
    units <- mapM getUnit commandStanceUnitIds
    pure . Just $ EventTypeMilitaryDisposition $ EventMilitaryDisposition {
        eventMilitaryDispositionUnits = map unitId units
      , eventMilitaryDispositionType = MilitaryDispositionStance commandStanceStance
      }
instance RunCommand CommandFormation where
  runCommand CommandFormation{..} = do
    units <- getUnitsForPlayer commandFormationUnitIds commandFormationPlayerId
    pure . Just $  EventTypeMilitaryDisposition $ EventMilitaryDisposition {
        eventMilitaryDispositionUnits = map unitId units
      , eventMilitaryDispositionType = MilitaryDispositionFormation commandFormationFormation
      }
instance RunCommand CommandGuard where
  runCommand CommandGuard{..} = do
    target <- getObject commandGuardGuarded
    units <- mapM getUnit commandGuardUnitIds

    pure . Just $ EventTypeTargetedMilitaryOrder $ EventTargetedMilitaryOrder {
        eventTargetedMilitaryOrderUnits = map unitId units
      , eventTargetedMilitaryOrderType = TargetedMilitaryOrderGuard
      , eventTargetedMilitaryOrderTarget = objectId target
      }
instance RunCommand CommandFollow where
  runCommand CommandFollow{..} = do
    target <- getObject commandFollowFollowed
    units <- mapM getUnit commandFollowUnitIds

    pure . Just $ EventTypeTargetedMilitaryOrder $ EventTargetedMilitaryOrder {
        eventTargetedMilitaryOrderUnits = map unitId units
      , eventTargetedMilitaryOrderType = TargetedMilitaryOrderFollow
      , eventTargetedMilitaryOrderTarget = objectId target
      }
instance RunCommand CommandPatrol where
  runCommand CommandPatrol{..} = do
    units <- mapM getUnit commandPatrolUnitIds

    pure . Just $ EventTypePatrol $ EventPatrol {
        eventPatrolUnits = map unitId units
      , eventPatrolWaypoints = commandPatrolWaypoints
      }
instance RunCommand CommandBuild where
  runCommand CommandBuild{..} = do
    units <- getUnitsForPlayer commandBuildBuilders commandBuildPlayerId

    pure . Just $ EventTypeBuild $ EventBuild {
        eventBuildBuilders = map unitId units
      , eventBuildPos = commandBuildPos
      , eventBuildingType = commandBuildBuildingType
      , eventBuildBuilding = Nothing
      }
instance RunCommand CommandResearch where
  runCommand CommandResearch{..} = do
    building <- getBuildingForPlayer commandResearchBuildingId commandResearchPlayerId

    pure . Just $ EventTypeResearch $ EventResearch {
        eventResearchBuilding = buildingId building
      , eventResearchTech = normalizeTech commandResearchResearch
      }
instance RunCommand CommandTrain where
  runCommand CommandTrain{..} = do
    building <- getBuilding commandTrainBuildingId
    pure . Just $ EventTypeTrain $ EventTrain {
        eventTrainBuilding = buildingId building
      , eventTrainType = commandTrainUnitType
      , eventTrainNumber = commandTrainNumber
      }
instance RunCommand CommandStop where
  runCommand CommandStop{..} = do
    objs <- mapM getObject commandStopSelectedIds

    pure . Just $ EventTypeStopGeneral $ EventStopGeneral {
        eventStopSelectedIds = map objectId objs
      }
instance RunCommand CommandWaypoint where
  runCommand CommandWaypoint{..} = do
    uids <- getSelectedObjectIds commandWaypointSelectedIds commandWaypointPlayerId
    objs <- getObjectsForPlayer uids commandWaypointPlayerId
    pure . Just $ EventTypeWaypoint $ EventWaypoint {
        eventWaypointSelectedObjects = map objectId objs,
        eventWaypointPos = commandWaypointPos
      }
instance RunCommand CommandRally where
  runCommand CommandRally{..} = do
    targetObj <-
      case (commandRallyTargetObject, commandRallyTargetType) of
        (Nothing, Nothing) -> pure Nothing
        (Just o, Just t) -> fmap Just $ getObjectAsType o t
        (a, b) -> error $ "Rally command with inconsistent targets " ++ show (a,b)

    buildings <- mapM getBuilding commandRallySelectedBuildingIds

    pure . Just $ EventTypeRally $ EventRally {
        eventRallyTargetObject = fmap objectId targetObj,
        eventRallyPos = commandRallyPos,
        eventRallyBuildings = map buildingId buildings
      }
instance RunCommand CommandDelete where
  runCommand CommandDelete{..} = do
    target <- getObjectForPlayer commandDeleteObjectId (Just commandDeletePlayerId)

    pure . Just $ EventTypeDelete $ EventDelete {
        eventDeleteObjectId = objectId target
      }



instance RunCommand CommandResign where
  runCommand CommandResign{..} = do
    pure . Just $ EventTypeResign $ EventResign {
        eventResignPlayerId = commandResignPlayerId
      }

instance RunCommand CommandAttackGround where
  runCommand CommandAttackGround{..} = do
    units <- mapM (fmap asUnit . (flip getObjectWithRestriction) OTRestrictionCanAttackGround) commandAttackGroundSelectedIds

    pure . Just $ EventTypeAttackGround $ EventAttackGround {
        eventAttackGroundUnitIds = map unitId units,
        eventAttackGroundPos = commandAttackGroundPos
      }

instance RunCommand CommandTribute where
  runCommand CommandTribute{..} = do
    pure . Just $ EventTypeTribute $ EventTribute {
        eventTributeFrom = commandTributeFrom,
        eventTributeTo = commandTributeTo,
        eventTributeResourceKind = commandTributeResourceKind,
        eventTributeAmount = commandTributeAmount,
        eventTributeTransationFee = commanndTributeTransationFee
      }

instance RunCommand CommandRepair where
  runCommand CommandRepair{..} = do
    units <- mapM getUnit commandRepairRepairers
    target <- getObject commandRepairRepaired
    pure . Just $ EventTypeRepair $ EventRepair {
      eventRepairRepaired = objectId target
    , eventRepairRepairers = map unitId units
    }

instance RunCommand CommandUngarrison where
  runCommand CommandUngarrison{..} = do
    objects <- case commandUngarrisonPos of
      Nothing -> mapM (fmap objectFromObjectBuilding . getBuilding) commandUngarrisonReleasedFrom
      Just _ -> mapM getObject commandUngarrisonReleasedFrom

    unit <- fmapMaybe getUnit commandUngarrisonObjectClicked
    pure . Just $ EventTypeUngarrison $ EventUngarrison {
      eventUngarrisonType = commandUngarrisonType
    , eventUngarrisonPos = commandUngarrisonPos
    , eventUngarrisonObjectClicked = fmap unitId unit
    , eventUngarrisonReleasedFrom = map objectId objects
    }

instance RunCommand CommandToggleGate where
  runCommand CommandToggleGate{..} = do
    b <- getBuilding commandToggleGateGate
    void $ updateObject $ setObjectTypes (objectFromObjectBuilding b) $ nonEmptyPartial [OT_Gate, OT_PalisadeGate]
    pure . Just $ EventTypeToggleGate $ EventToggleGate {
      eventToggleGateGate = buildingId b
    }

instance RunCommand CommandGarrison where
  runCommand c@CommandGarrison{..} =
    if commandGarrisonType `elem` [GarrisonTypePack, GarrisonTypeUnpack]
      then do
        trebs <- mapM (\i -> fmap asUnit $ getObjectAsType i OT_TrebuchetPacked) commandGarrisonSelectedIds
        pure . Just $ EventTypePackOrUnpack $ EventPackOrUnpack {
          eventPackOrUnpackTrebuchets = map unitId trebs
        , eventPackOrUnpackPacked = commandGarrisonType == GarrisonTypePack
        }
      else
        if commandGarrisonType == GarrisonTypeGarrison
          then do
            case commandGarrisonTargetId of
              Nothing -> do
                traceShowM c
                error "Garrisoning should have a target!"
              Just t -> do
                 units <- mapM getUnit commandGarrisonSelectedIds
                 target <- getObject t
                 pure . Just $ EventTypeGarrison $ EventGarrison {
                    eventGarrisonTargetId = objectId target
                  , eventGarrisonGarrisonedUnits = map unitId units
                  , eventGarrisonPos = commandGarrisonPos
                  }

          else do
            traceShowM $ c
            traceM $ "Weird garrison command!!!"
            pure Nothing


instance RunCommand CommandSell where
  runCommand CommandSell{..} = do
    _ <- getBuildingForPlayer commandSellMarket commandSellPlayer

    market <- fmap asBuilding $ getObjectAsType commandSellMarket OT_Market
    pure . Just $ EventTypeUseMarket $ EventUseMarket {
        eventUseMarketBuyOrSell = Sell
      , eventUseMarketKind = commandSellKind
      , eventUseMarketAmount = commandSellAmount
      , eventUseMarketMarket = buildingId market

      }

instance RunCommand CommandBuy where
  runCommand CommandBuy{..} = do
    _ <- getBuildingForPlayer commandBuyMarket commandBuyPlayer
    market <- fmap asBuilding $ getObjectAsType commandBuyMarket OT_Market
    pure . Just $ EventTypeUseMarket $ EventUseMarket {
        eventUseMarketBuyOrSell = Buy
      , eventUseMarketKind = commandBuyKind
      , eventUseMarketAmount = commandBuyAmount
      , eventUseMarketMarket = buildingId market

      }


instance RunCommand CommandDropRelic where
  runCommand CommandDropRelic{..} = do
    m <- fmap asUnit $ getObjectAsType commandDropRelicMonkId OT_Monk
    pure . Just $ EventTypeDropRelic $ EventDropRelic {
      eventDropRelicMonkId = unitId m
    }

instance RunCommand CommandTownBell where
  runCommand CommandTownBell{..} = do
    m <- fmap asBuilding $ getObjectAsType commandTownBellTownCenter OT_TownCenter
    pure . Just $ EventTypeTownBell $ EventTownBell {
      eventTownBellTownCenter = buildingId m,
      eventTownBellActive = commandTownBellActive
    }

instance RunCommand CommandBackToWork where
  runCommand CommandBackToWork{..} = do
    m <- getBuilding commandBackToWorkBuildingId
    pure . Just $ EventTypeBackToWork $ EventBackToWork {
      eventBackToWorkBuildingId = buildingId m
    }

instance RunCommand CommandWall where
  runCommand CommandWall{..} = do

    units <- getUnitsForPlayer commandWallBuilders commandWallPlayerId
    pure . Just $ EventTypeWall $ EventWall {
      eventWallStartPos = commandWallStartPos
    , eventWallEndPos = commandWallEndPos
    , eventWallBuildingType = commandWallBuildingType
    , eventWallBuilders = map unitId units
    }