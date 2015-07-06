{-# LANGUAGE MultiParamTypeClasses,FunctionalDependencies #-}
module Client.Sources where

import Control.Monad.State
import Control.Concurrent
import Data.List
import Data.Maybe
import Data.Binary
import qualified Data.Map as M

import Client.Class
import Client.Crypto
import Client.Packet
import Client.Routing
import Client.Pipes
import Client.Communication
import Log

type Sources = MapModule SourceEntry SourceID Request SourceAnswer
type SourceT = StateT Sources

type SourceCB = MapBehaviour SourceEntry SourceID Request SourceAnswer
data SourceAnswer = SourceAnswer { sourceAnsID :: SourceID,
                                   sourceAnswer :: Maybe (DataCB, MVar Pipes)} 

{- TODO Associer un pipe à une route -}
data SourceEntry =  SourceEntry {sourceID :: SourceID,
                                 sourcePipes :: MVar Pipes, 
                                 sourceFreeComID :: MVar [ComID],
                                 sourceCommunication :: MVar Communication}
instance Eq SourceEntry where sE == sE' = sourceID sE == sourceID sE'

instance MapModules SourceEntry SourceID Request SourceAnswer where
        packetKey (Request _ _ _ [] _ _ _ ) = return Nothing
        packetKey req = return . Just  $ if 0 == roadPosition req then last $ road req
                                                                 else head $ road req
        entryBehaviour (SourceEntry sID pV _ cV) = [\_ r -> return [SourceAnswer sID $ Just (genCommunicationCallback pV cV (roadPosition r) $ roadToRoadID (road r), pV)]]

sendToSource :: SourceEntry -> ComMessage -> IO Bool
sendToSource sE cm = do (pL, pM) <- withMVar (sourcePipes sE) (pure . ((,) <$> pipesList <*> pipesMap))
                        case pL of [] ->  pure False
                                   rID:_ ->  maybe (pure False) (($cm) . writeFun) (M.lookup rID $ pM)



getSourceEntry :: MVar Sources -> SourceID -> IO (Maybe SourceEntry)
getSourceEntry sV sID = withMVar sV $ pure . M.lookup sID . keyMap

removeSourceEntry :: MVar Sources -> SourceID -> RawData -> IO () 
removeSourceEntry sV sID d = modifyMVar_ sV $ \s -> do let (msE, kM) = M.updateLookupWithKey (pure $ pure Nothing) sID $ keyMap s
                                                       maybe (pure ()) (breakComAndPipes) msE
                                                       pure s{keyMap = kM}
           where breakComAndPipes sE@(SourceEntry _ pV iV cV) = breakCom cV sE >> modifyMVar_ pV breakPipes >> modifyMVar_ iV (pure $ pure [])
                 breakPipes pM = do forM (pipesMap pM) $ ($d) . breakFun
                                    pure (Pipes M.empty [])
                 breakCom :: MVar Communication -> SourceEntry -> IO ()
                 breakCom cV sE = do modifyMVar_ cV $ \s -> do liftIO $ execStateT (mapM (sendBrk sE)  $ M.assocs (keyMap s)) s
                                                               pure $ newMapModule []
                 sendBrk sE (cID, ComEntry cCBL) = do sequence $ map ($ComExit cID (encode "source removed locally")) cCBL
                                                      void . liftIO $ sendToSource sE $ ComExit cID (encode "source removed by peer")
                                                     
                                                       



-- | Standard DestCallback for routing
pipesRoutingCallback ::  PrivKey -> PubKey -> SendFunction -> MVar Sources -> RoutingCB
pipesRoutingCallback uK pK send sV = genCallback sV inFun outFun
    where inFun req = return [req]
          outFun r (SourceAnswer sID sAnsM) = case sAnsM of
                                                Nothing -> pure []
                                                Just (dCB, pV) -> do (onBrk, pL) <- addNewPipe uK pK send pV r
                                                                     return [RoutingAnswer (onBrk >> chkSource pV sID) (Just [dCB]) pL ]
          chkSource pV sID = do b <- withMVar pV $ pure . null . pipesList
                                if b then removeSourceEntry sV sID (encode ()) 
                                     else pure ()


