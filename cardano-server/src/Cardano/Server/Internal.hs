{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}

module Cardano.Server.Internal
    ( module Cardano.Server.Class
    , NetworkM (..)
    , AppM (..)
    , runAppM
    , getNetworkId
    , getQueueRef
    , loadEnv
    , checkEndpointAvailability
    ) where

import           Cardano.Node.Emulator         (Params (..), pParamsFromProtocolParams)
import           Cardano.Server.Class          (Env (..), HasServer (..), Queue, QueueRef)
import           Cardano.Server.Config         (Config (..), InactiveEndpoints, decodeOrErrorFromFile, loadConfig)
import           Cardano.Server.Utils.Logger   (HasLogger (..))
import           Control.Monad.Catch           (MonadCatch, MonadThrow (..))
import           Control.Monad.Except          (MonadError)
import           Control.Monad.Extra           (whenM)
import           Control.Monad.IO.Class        (MonadIO)
import           Control.Monad.Reader          (MonadReader, ReaderT (ReaderT, runReaderT), asks)
import           Data.Default                  (def)
import           Data.IORef                    (newIORef)
import           Data.Maybe                    (fromMaybe)
import           Data.Sequence                 (empty)
import           Ledger                        (NetworkId)
import qualified PlutusAppsExtra.IO.Blockfrost as BF
import           PlutusAppsExtra.IO.ChainIndex (HasChainIndex)
import           PlutusAppsExtra.IO.Wallet     (HasWallet (..))
import           Servant                       (Handler, err404)
import qualified Servant

newtype NetworkM s a = NetworkM { unNetworkM :: ReaderT (Env s) Handler a }
    deriving newtype
        ( Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadReader (Env s)
        , MonadError Servant.ServerError
        , MonadThrow
        , MonadCatch
        , HasWallet
        , HasChainIndex
        )

instance HasLogger (NetworkM s) where
    loggerFilePath = "server.log"

instance BF.HasBlockfrost (NetworkM s) where
  getBfToken = asks envBfToken
  getNetworkId = getNetworkId

getQueueRef :: NetworkM s (QueueRef s)
getQueueRef = asks envQueueRef

getNetworkId :: MonadReader (Env s) m => m NetworkId
getNetworkId = asks $ pNetworkId . envLedgerParams

loadEnv :: forall s. HasServer s => IO (Env s)
loadEnv = do
    Config{..}   <- loadConfig
    envQueueRef  <- newIORef empty
    envWallet    <- sequence $ decodeOrErrorFromFile <$> cWalletFile
    envAuxiliary <- loadAuxiliaryEnv @s cAuxiliaryEnvFile
    pp           <- decodeOrErrorFromFile "protocol-parameters.json"
    let envMinUtxosNumber    = cMinUtxosNumber
        envMaxUtxosNumber    = cMaxUtxosNumber
        envLedgerParams      = Params def (pParamsFromProtocolParams pp) cNetworkId
        envInactiveEndpoints = cInactiveEndpoints
        envCollateral        = cCollateral
        envNodeFilePath      = cNodeFilePath
        envChainIndex        = fromMaybe (defaultChainIndex @s) cChainIndex
        envBfToken           = cBfToken
    print cBfToken
    pure Env{..}

newtype AppM s a = AppM { unAppM :: ReaderT (Env s) IO a }
    deriving newtype 
        ( Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadReader (Env s)
        , MonadThrow
        , MonadCatch
        , HasWallet
        , HasChainIndex
        )

runAppM :: HasServer s => AppM s a -> IO a
runAppM app = loadEnv >>= runReaderT (unAppM app)

instance HasLogger (AppM s) where
    loggerFilePath = "server.log"

instance BF.HasBlockfrost (AppM s) where
  getBfToken = asks envBfToken
  getNetworkId = getNetworkId

checkEndpointAvailability :: (InactiveEndpoints -> Bool) -> NetworkM s ()
checkEndpointAvailability endpoint = whenM (asks (endpoint . envInactiveEndpoints)) $ throwM err404