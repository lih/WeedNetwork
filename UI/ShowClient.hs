{-# LANGUAGE ImpredicativeTypes, RankNTypes, FlexibleInstances, UndecidableInstances, MultiParamTypeClasses, FunctionalDependencies #-}
module UI.ShowClient where

import Reactive.Banana
import Reactive.Banana.Frameworks
import qualified Data.Map as M
import Control.Monad
import qualified Data.Array as A

import Class
import Routing
import Ressource
import Neighbors
import Pipes
import Client
import Client
import Network
import UI.App



renderClients cEventsL = buildApp $ zip (map show [1..]) (concatMap renderClient cEventsL)

renderClient :: ClientInterface -> [A.Array (Int,Int) (AddHandler String)] --[A.Array (Int,Int) (AddHandler String)]
renderClient cInterface = [win1,win2,win3]
    where [neigh,rLoc,rRel,pMap,resLocal, resListen, output, routLog, pipeLog] = showClientEvent' cInterface
          win1 = A.array ((1,1),(2,2)) $ [((1,1),rLoc),((1,2),rRel),
                                            ((2,1),neigh), ((2,2),pMap)]
          win2 = A.listArray ((1,1),(1,2)) $ [resLocal, resListen, output, routLog]
          win3 = A.listArray ((1,1),(1,1)) $ [pipeLog]
showClientEvent' :: ClientInterface -> [AddHandler String]
showClientEvent' cInterface = [dump "NEIGHBORS" cleNeighborsMap, dump "ROUTING LOCAL" cleRoutingLocalMap, dump "ROUTING RELAY" cleRoutingRelayedMap]
                        ++ [showPipeMap <$> clePipeManager (ciEvents cInterface)] ++ [dump "RESSOURCE LOCAL" cleResLocalMap, dump "RESSOURCE LISTEN" cleResListenMap]
                        ++ [show  <$> ciOutput cInterface, 
                           cleRoutingLogs $ ciEvents cInterface, 
                           clePipeLogs $ ciEvents cInterface]
    where dump name f = showMapKeys name <$> f (ciEvents cInterface)


showMapKeys :: Show k => String -> M.Map k a -> String
showMapKeys name m = name ++"\n\n" ++ (unlines $ show <$> M.keys m)
showPipeMap :: (Show k, Show l) => M.Map k (M.Map l a) -> String
showPipeMap m = unlines $ ("PIPES\n\n":map f (M.toList m))
  where f (k,v) = show k ++ "\n"
                ++ unlines (map (\l -> "\t" ++ show l) (M.keys v))

          
