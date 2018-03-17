{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Servant.Streaming.Example (main) where

import Data.Conduit                       (($$))
import Data.Conduit.List                  as CL
import qualified Data.Conduit.Combinators as CC
import Servant
import Network.Wai.Handler.Warp           (run)

import           Servant.Streaming.Server
import           Streaming                hiding (run)
import qualified Streaming.Prelude        as S


type API = "getfile" :> StreamResponseGet '[OctetStream]

server :: Server API
server = return $ hoist lift (CC.sourceFileBS "bigfile") $$ CL.mapM_ S.yield

api :: Proxy API
api = Proxy

app1 :: Application
app1 = serve api server

main :: IO ()
main = do
    print "serving on 8081"
    run 8081 app1
