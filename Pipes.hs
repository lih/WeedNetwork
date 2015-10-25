{-# LANGUAGE DeriveGeneric #-}
module Pipes where

import Crypto
import Routing 
import Class


import Reactive.Banana
import Reactive.Banana.Frameworks
import qualified Data.Map as M

type PipesSender = Handler PipeMessage
type PipeCloser = Handler (SourceID, PipeID)
type NewSourceEvent t = Event t (SourceID, AddHandler NewPipe)


type PipesMap = M.Map PipeID (AddHandler PipeMessage, PipesSender)

data PipeManagerEntry =  PipeManagerEntry { pmeFireNP :: Handler NewPipe,
                                            pmeUnregister :: IO (),
                                            pmePipeMap :: PipesMap,
                                            pmeModifier :: Modifier PipesMap}

type PipesManager = M.Map SourceID PipeManagerEntry
type PipesManagerBhv t = ModEvent t PipesManager

data Pipes t = Pipes {pipesManager :: PipesManagerBhv t,
                      pipesDataManager :: Event t DataManager,
                      pipeNewSourceEvent :: NewSourceEvent t,
                      pipesMessagesOut :: Event t PipePacket,
                      pipesClosePipe :: PipeCloser,
                      pipesSendOnPipe :: Handler (SourceID, PipeID, RawData),
                      pipesRemoveSource :: Handler SourceID,
                      pipesLogs :: Event t String} 


buildPipes :: Frameworks t => Event t NewPipe -> Moment t (Pipes t)
buildPipes npE = do (closeE, closeH) <- newEvent
                    (remSE, remSH) <- newEvent
                    --Contruction du pipeManager
                    (pipeManB, sendE, newSourceE) <- buildPipeManager npE
                    --Reactimate des suppressions de pipes et de sources
                    reactimate $ closePipe (meModifier pipeManB) <$> closeE
                    reactimate $ applyMod removeSource pipeManB remSE
                    --Fermeture des pipes lors de receptions de PipeClose
                    let dataMan = buildDataManager $ meChanges pipeManB
                    reactimate . (closeH <$>) =<< closePipeEvent dataMan
                    sendH <- sendOnPipe pipeManB 
                    --Retour de la structure
                    logsE <- (("PIPES : " ++) <$>) <$> showDataManager dataMan
                    pure $ Pipes pipeManB dataMan newSourceE sendE closeH sendH remSH logsE
    where closePipe mod (sID, pID) = mod $ M.adjust (deletePipe pID) sID
          removeSource :: Modifier PipesManager -> PipesManager -> SourceID -> IO ()
          removeSource manM man sID = case M.lookup sID man of
                                                  Nothing -> pure ()
                                                  Just pme -> do pmeUnregister pme
                                                                 manM $ M.delete sID
          {- | Send messages to sources, if there is pipes leading to them.
          -   [TODO] : choix du pipes (head pour l'instant...)
          -   [TODO] : closePipe sur les pipeClose Messages
          -   [TODO] : keeplogs -}
          sendOnPipe pm = do (sE,sH) <- newEvent
                             reactimate $ apply (send <$> meLastValue pm) sE
                             pure sH
              where send :: PipesManager -> (SourceID, PipeID, RawData) -> IO ()
                    send pm (sID,pID,d) = maybe (pure ()) (makeMessage pID d) $ M.lookup sID pm >>= M.lookup pID . pmePipeMap 
                    makeMessage pID d (_,s) = s $ Right (pID, d)





closePipeEvent :: Frameworks t => Event t DataManager -> Moment t (Event t (SourceID, PipeID))
closePipeEvent dmE = mergeEvents $  M.mapWithKey filterClose <$> dmE
    where filterClose sID e = (,) sID . fst . fromLeft <$> filterIO (pure . isLeft) e

type DataManager = EventMap SourceID PipeMessage
buildDataManager :: Event t PipesManager -> Event t DataManager
buildDataManager pManaB = (mergeEntry <$> ) <$> pManaB
    where mergeEntry :: PipeManagerEntry -> AddHandler PipeMessage
          mergeEntry = allAddHandlers . (fst <$>) . pmePipeMap 


{-| Converts the map of physical neighbors into a map of recipients |-}
buildPipeManager :: Frameworks t =>  Event t NewPipe -> Moment t (PipesManagerBhv t, Event t PipePacket, NewSourceEvent t)
buildPipeManager npE = do manM <- newModEvent M.empty
                          (nsE, nsH) <- newEvent
                          (sendE, sendH) <- newEvent
                          reactimate $ applyMod (onNewPipe nsH sendH) manM npE
                          pure (manM, sendE, nsE)
  where onNewPipe :: Handler (SourceID, AddHandler NewPipe) -> Handler PipePacket -> Modifier PipesManager -> PipesManager -> NewPipe -> IO ()
        onNewPipe nsH sendH mod rM np = case sID `M.lookup` rM of
                                     Just pme -> pmeFireNP pme $ np
                                     Nothing -> do (e, h) <- newAddHandler
                                                   unreg <- buildPipeMap sendH e pipeMapMod
                                                   mod $ M.insert sID $ PipeManagerEntry h unreg M.empty pipeMapMod
                                                   nsH (sID, e)
                                                   h np
                where sID = npSource np
                      pipeMapMod :: (PipesMap -> PipesMap) -> IO ()
                      pipeMapMod f = mod $ M.adjust (\pme -> pme{pmePipeMap = f $ pmePipeMap pme}) sID


buildPipeMap :: Handler PipePacket -> AddHandler NewPipe -> Modifier PipesMap -> IO (IO ())
buildPipeMap sendH npE = register $  onNewPipe <$> npE
    where onNewPipe :: NewPipe -> PipesMap -> PipesMap
          onNewPipe np pM = case pID `M.lookup` pM of
                                Nothing -> M.insert pID (npMessageEvent np, sendH . npSender np) pM
                                Just _ -> pM
            where pID = npPipeID np

deletePipe :: PipeID -> PipeManagerEntry -> PipeManagerEntry
deletePipe pID pme = pme{pmePipeMap = M.delete pID $ pmePipeMap pme}


showDataManager :: Frameworks t => Event t DataManager -> Moment t (Event t String)
showDataManager e = mergeEvents $ M.mapWithKey showE <$> e
    where showE sID ah = (("Source : " ++ show sID ++ " -> ") ++) . show <$> ah
