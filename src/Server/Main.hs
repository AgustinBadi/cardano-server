{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Server.Main where

import           Control.Concurrent           (forkIO)
import           Control.Monad.Except         (runExceptT)
import           Control.Monad.Reader         (ReaderT(runReaderT))
import           Utils.Logger                 (HasLogger(logMsg))
import qualified Network.Wai.Handler.Warp     as Warp
import qualified Network.Wai.Middleware.Cors  as Cors
import qualified Servant
import           Servant                      (Proxy(..), type (:<|>)(..), ServerT, Context(EmptyContext), hoistServer,
                                               serveWithContext, Application, runHandler')
import           Server.Endpoints.Funds       (FundsApi, fundsHandler)
import           Server.Endpoints.Tx.Class    (HasTxEndpoints)
import           Server.Endpoints.Tx.Submit   (SubmitTxApi, submitTxHandler, processQueue)
import           Server.Endpoints.Tx.New      (NewTxApi, newTxHandler)
import           Server.Endpoints.Ping        (PingApi, pingHandler)
import           Server.Class                 (NetworkM(unNetworkM), Env, loadEnv, checkForCleanUtxos)
import           System.IO                    (stdout, BufferMode(LineBuffering), hSetBuffering)

type ServerAPI s
    =    PingApi
    :<|> SubmitTxApi s
    :<|> NewTxApi s
    :<|> FundsApi

type ServerConstraints s =
    ( HasTxEndpoints s
    , Servant.HasServer (ServerAPI s) '[]
    )

server :: HasTxEndpoints s => ServerT (ServerAPI s) (NetworkM s)
server = pingHandler
    :<|> submitTxHandler
    :<|> newTxHandler
    :<|> fundsHandler

serverAPI :: forall s. Proxy (ServerAPI s)
serverAPI = Proxy @(ServerAPI s)

port :: Int
port = 3000

runServer :: forall s. ServerConstraints s => IO ()
runServer = do
        env <- loadEnv
        hSetBuffering stdout LineBuffering
        forkIO $ processQueue env
        prepareServer env 
        Warp.run port $ mkApp @s env
    where
        prepareServer env = runExceptT . runHandler' . flip runReaderT env . unNetworkM $ do 
            logMsg "Starting server..."
            checkForCleanUtxos

mkApp :: forall s. ServerConstraints s => Env s -> Application
mkApp env = Cors.simpleCors $ serveWithContext (serverAPI @s) EmptyContext $
    hoistServer (serverAPI @s) ((`runReaderT` env) . unNetworkM) server