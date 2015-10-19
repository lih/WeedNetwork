{-# LANGUAGE DeriveGeneric,MultiParamTypeClasses #-}
module Ressource where

import Class
import Crypto
import Routing

import Data.ByteString hiding (split)
import Data.Binary
import Control.Monad
import qualified Data.Map as M
import Control.Lens
import Reactive.Banana
import Reactive.Banana.Frameworks

import GHC.Generics

type TTL = Int


newtype RessourceID = RessourceID RawData
    deriving (Eq,Ord,Generic)

-- TODO
ttlMax = 10
maxDelay = 10


data RessourceCert = RessourceCert {cResSourceDHKey :: DHPubKey,
                                    cResSourceKey :: PubKey,
                                    cResTimestamp :: Time,
                                    cResID :: RessourceID,
                                    cResSig :: Signature}
                deriving Generic

type RessourcePacket = Either Research Answer

data Research = Research {resID :: RessourceID,
                          resTTL :: TTL,
                          resRoad :: Road,
                          resCnt :: RawData}
                deriving Generic
data Answer = Answer {ansCert :: RessourceCert,
                      ansTTL :: TTL,
                      ansRoad :: Road,
                      ansSourceID :: SourceID,
                      ansCnt :: RawData}
                deriving Generic


type AnswerMap = EventEntryMap RessourceID Answer
type AnswerMapBhv t = ModEvent t AnswerMap

instance IDable Answer RessourceID where
        extractID = cResID . ansCert

instance SignedClass Answer where scHash (Answer c _ _ sID r) = encode (c, sID, r)
                                  scKeyHash = ansSourceID
                                  scSignature = cResSig . ansCert
                                  scPushSignature a s = a{ansCert = (ansCert a){cResSig = s} }
instance IntroClass Answer where icPubKey = cResSourceKey . ansCert 

type RessourceMapTpl = M.Map RessourceID ()
type RelayMapBhv t = ModEvent t RessourceMapTpl


data Ressources t = Ressources {resAnswerMap :: AnswerMapBhv t,
                                resRelayMap :: RelayMapBhv t,
                                resRelPackets :: Event t RessourcePacket }

buildRessources :: Frameworks t => DHPubKey -> KeyPair -> RessourceMapTpl -> Event t RessourceID -> Event t Research -> Event t Answer -> Moment t (Ressources t)
buildRessources dhPK kP locMap rIDE resE ansE = do (relMap, relPE) <- buildRelayMap dhPK kP locMap resE ansE
                                                   ansB <- buildAnswerMap rIDE ansE
                                                   pure $ Ressources ansB relMap relPE


buildRelayMap :: Frameworks t => DHPubKey -> KeyPair -> RessourceMapTpl -> Event t Research -> Event t Answer -> Moment t (RelayMapBhv t, Event t RessourcePacket)
buildRelayMap dhPK (sK,pK) locRMap resE ansE = do relModE <- newModEvent M.empty
                                                  let resP = filterJust $  apply (onResearch (meModifier relModE) <$> meLastValue relModE) resE 
                                                      ansP = filterJust $ apply (onAnswer <$> meLastValue relModE) ansE 
                                                  reactimate $ fst <$> resP
                                                  pure (relModE, union (Left . snd <$> resP) (Right <$> ansP))
        where onResearch :: Modifier RessourceMapTpl -> RessourceMapTpl -> Research -> Maybe (IO (), Research)
              onResearch mod map res = case resID res `M.lookup` map of
                                            Just _ -> Nothing
                                            Nothing ->  Just (mod $ M.insert (resID res) (), relayRes res)
              onAnswer :: RessourceMapTpl -> Answer -> Maybe Answer
              onAnswer map ans = pure (relayAns ans) <$> extractID ans `M.lookup` map 
              relayAns :: Answer -> Answer
              relayAns = id
              relayRes = id


{- | Event des recherches sortantes, et des Answer entrantes. Construit la map des Event Answer nous concernants.-}
buildAnswerMap :: Frameworks t => Event t RessourceID -> Event t Answer -> Moment t (AnswerMapBhv t)
buildAnswerMap rE aE = do  aModE <- newModEvent M.empty
                           -- listening the researchs
                           reactimate $ apply (onResearch (meModifier aModE) <$> meLastValue aModE) rE
                           reactimate . filterJust $ apply (fireKey <$> meLastValue aModE) aE
                           pure aModE
    where onResearch :: Modifier AnswerMap -> AnswerMap -> RessourceID -> IO ()
          onResearch order aMap r = case r `M.lookup` aMap of
                                      Just _ -> pure ()
                                      Nothing ->  do e <- newEventEntry $ (r==) . extractID
                                                     order $ M.insert r e



{-
checkCert source time (RessourceCert dhKey pKey sendTime rID sig) = time - sendTime < maxDelay
                                                                    && computeHashFromKey pKey == source
                                                                    && checkSig pKey sig (encode (dhKey,pKey,sendTime,rID))
checkAnswer me time ans = ansTTL ans > 1 && ansTTL ans <= ttlMax &&
                          me `Prelude.notElem` ansRoad ans && checkCert (ansSourceID ans) time (ansCert ans)

-}



instance Binary RessourceID
instance Binary RessourceCert
instance Binary Research
instance Binary Answer

