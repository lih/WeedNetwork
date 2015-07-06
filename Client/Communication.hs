{-# LANGUAGE MultiParamTypeClasses,FunctionalDependencies #-}
module Client.Communication where

import Control.Monad.State hiding (put, get)
import qualified Control.Monad.State  as S (get)
import Control.Concurrent
import Data.Binary 
import Data.List
import qualified Data.Map as M

import Client.Class
import Client.Crypto
import Client.Packet
import Client.Routing
import Client.Pipes
import Log


type Communication = MapModule ComEntry ComID ComMessage () 
type ComCB = Behaviour Communication ComMessage () 
type ComT = StateT Communication

data ComEntry = ComEntry {comCallback :: [ComCB]}

instance MapModules ComEntry ComID ComMessage () where
        packetKey cm = do keepLog CommunicationLog Normal $ "receivedComMess : " ++ show cm
                          S.get >>= keepLog CommunicationLog Normal . show
                          return . Just $ comID cm
        entryBehaviour cE = map (\x -> (\_ -> x)) $ comCallback cE



insertComCallback :: MVar Communication -> ComID -> ComCB -> IO ()
insertComCallback cV cID clbk = modifyMVar_ cV $ \s -> pure s{keyMap = M.insert cID (ComEntry [clbk]) $ keyMap s}

closeComIO :: MVar [ComID] -> MVar Communication -> ComID -> IO ()
closeComIO fV cV cID = runStateMVar cV $ closeCom fV cID
                        

closeCom :: MonadIO m => MVar [ComID] -> ComID -> ComT m ()
closeCom fV cID =  do keepLog CommunicationLog Important $ "Closing communication : " ++ show cID
                      modify $ \s -> s{keyMap = M.delete cID $ keyMap s}
                      liftIO . modifyMVar_ fV $ pure .(++ [cID])



defaultComCallback :: Modules a p r => MVar a 
                                   -> (ComMessage -> Maybe p)
                                   -> (ComID -> p -> r -> IO (Maybe ComCB))
                                   -> ComCB
defaultComCallback mv iFun oFun p = case iFun p of
                                        Nothing -> return []
                                        Just q -> do keepLog CommunicationLog Important $ "calling comCB"
                                                     genCallback mv (pure . pure . pure $ q) (outFun q) p
    where outFun q p r = do comCBM <- liftIO $ oFun (comID p) q r
                            case comCBM of
                              Nothing -> pure []
                              Just cCB -> insertMapBehaviour (comID p) (ComEntry $ [cCB]) >> pure []






genCommunicationCallback :: MVar Pipes -> MVar Communication -> Number -> RoadID -> DataCB
genCommunicationCallback pV cV n0 rID = DataCB hFun clbk
    where hFun :: HashFunction (Either ComMessage Packet)
          hFun (DataPacket kH _ (DataContent cnt)) = case decodeMaybe cnt of
                                        Nothing -> return Nothing
                                        Just (PipeData n b cm) -> if n == n0 then do keepLog CommunicationLog Normal $ "received pipeData on pipe : " ++ show kH 
                                                                                     case decodeMaybe cm of Nothing -> do keepLog CommunicationLog Error "fail to decode" 
                                                                                                                          pure Nothing 
                                                                                                            Just x -> do keepLog CommunicationLog Normal $ show x 
                                                                                                                         return $ Just (pipeMessageHash kH b cm, Left x)
                                                                             else pure Nothing
                                        Just (PipeExit n _ _) -> if n == n0 then do unregisterKeyEntry kH
                                                                                    removePipe pV rID
                                                                                    return  Nothing
                                                                            else pure Nothing
          hFun p@(Introduce kH _ _ (IntroContent cnt)) = case decodeMaybe cnt :: Maybe Request of
                                                             Nothing -> pure Nothing
                                                             Just req -> if n0 == 0 && roadPosition req == n0 then
                                                                               return $ Just (reqSourceHash kH req, 
                                                                                         Right p{introContent = IntroContent $ encode req{roadPosition = roadPosition req + 1}})
                                                                         else pure Nothing 
          clbk :: CryptoCB (Either ComMessage Packet) Packet
          clbk (Left cm) = do liftIO . forkIO $  (runModule cV cm :: IO [()]) >> pure ()
                              return []
          clbk (Right pkt) = pure [pkt]






