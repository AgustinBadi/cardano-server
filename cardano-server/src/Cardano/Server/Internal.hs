{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Cardano.Server.Internal where

import           Cardano.Node.Emulator             (Params (..), pParamsFromProtocolParams)
import           Cardano.Server.Config             (Config (..), InactiveEndpoints, decodeOrErrorFromFile, loadConfig)
import           Cardano.Server.Error.CommonErrors (InternalServerError (NoWalletProvided))
import           Cardano.Server.Input              (InputContext)
import           Cardano.Server.Utils.Logger       (HasLogger (..))
import           Control.Exception                 (throw)
import           Control.Monad.Catch               (MonadCatch, MonadThrow (..))
import           Control.Monad.Except              (MonadError)
import           Control.Monad.Extra               (join, whenM)
import           Control.Monad.IO.Class            (MonadIO)
import           Control.Monad.Reader              (MonadReader, ReaderT (ReaderT, runReaderT), asks)
import           Data.Default                      (Default (..))
import           Data.Functor                      ((<&>))
import           Data.IORef                        (IORef, newIORef)
import           Data.Kind                         (Type)
import           Data.Maybe                        (fromMaybe)
import           Data.Sequence                     (Seq, empty)
import           Ledger                            (Address, NetworkId, TxOutRef)
import qualified PlutusAppsExtra.IO.Blockfrost     as BF
import           PlutusAppsExtra.IO.ChainIndex     (ChainIndex, HasChainIndex (..))
import           PlutusAppsExtra.IO.Wallet         (HasWallet (..), RestoredWallet)
import           PlutusAppsExtra.Types.Tx          (TransactionBuilder)
import           Servant                           (Handler, err404)
import qualified Servant

newtype ServerM api a = ServerM {unServerM :: ReaderT (Env api) Handler a}
     deriving newtype
        ( Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadReader (Env api)
        , MonadError Servant.ServerError
        , MonadThrow
        , MonadCatch
        )

runServerM :: Env api -> ServerM api a -> IO a
runServerM env = fmap (either throw id) . Servant.runHandler . (`runReaderT` env) . unServerM

instance HasLogger (ServerM api) where
    loggerFilePath = asks envLoggerFilePath

instance BF.HasBlockfrost (ServerM api) where
    getBfToken = asks envBfToken
    getNetworkId = getNetworkId

instance HasWallet (ServerM api) where
    getRestoredWallet = asks envWallet <&> fromMaybe (throw NoWalletProvided)

instance HasChainIndex (ServerM api) where
    getChainIndex = asks envChainIndex

type family TxApiRequestOf api :: Type

type family InputOf api :: Type

type family AuxillaryEnvOf api :: Type

type InputWithContext api = (InputOf api, InputContext)

type Queue api = Seq (InputWithContext api)

type QueueRef api = IORef (Queue api)

data Env api = Env
    { envQueueRef              :: QueueRef api
    , envWallet                :: Maybe RestoredWallet
    , envAuxiliary             :: AuxillaryEnvOf api
    , envBfToken               :: BF.BfToken
    , envMinUtxosNumber        :: Int
    , envMaxUtxosNumber        :: Int
    , envLedgerParams          :: Params
    , envCollateral            :: Maybe TxOutRef
    , envNodeFilePath          :: FilePath
    , envChainIndex            :: ChainIndex
    , envInactiveEndpoints     :: InactiveEndpoints
    , envLoggerFilePath        :: Maybe FilePath
    , envGetTrackedAddresses   :: ServerM api [Address]
    , envTxEndpointsTxBuilders :: InputOf api -> ServerM api [TransactionBuilder ()]
    , envServerIdle            :: ServerM api ()
    , envProcessRequest        :: TxApiRequestOf api -> ServerM api (InputWithContext api)
    }

serverTrackedAddresses :: ServerM api [Address]
serverTrackedAddresses = join $ asks envGetTrackedAddresses

txEndpointsTxBuilders :: InputOf api -> ServerM api [TransactionBuilder ()]
txEndpointsTxBuilders input = asks envTxEndpointsTxBuilders >>= ($ input)

serverIdle :: ServerM api ()
serverIdle = join $ asks envServerIdle

getQueueRef :: ServerM api (QueueRef api)
getQueueRef = asks envQueueRef

getNetworkId :: ServerM api NetworkId
getNetworkId = asks $ pNetworkId . envLedgerParams

loadEnv :: ChainIndex
        -> ServerM api [Address]
        -> (InputOf api -> ServerM api [TransactionBuilder ()])
        -> ServerM api ()
        -> (TxApiRequestOf api -> ServerM api (InputWithContext api))
        -> AuxillaryEnvOf api
        -> IO (Env api)
loadEnv defaultCI envGetTrackedAddresses envTxEndpointsTxBuilders envServerIdle envProcessRequest envAuxiliary = do
    Config{..}   <- loadConfig
    envQueueRef  <- newIORef empty
    envWallet    <- sequence $ decodeOrErrorFromFile <$> cWalletFile
    pp           <- decodeOrErrorFromFile "protocol-parameters.json"
    let envMinUtxosNumber    = cMinUtxosNumber
        envMaxUtxosNumber    = cMaxUtxosNumber
        envLedgerParams      = Params def (pParamsFromProtocolParams pp) cNetworkId
        envInactiveEndpoints = cInactiveEndpoints
        envCollateral        = cCollateral
        envNodeFilePath      = cNodeFilePath
        envChainIndex        = fromMaybe defaultCI cChainIndex
        envBfToken           = cBfToken
        envLoggerFilePath    = Nothing
    print cBfToken
    pure Env{..}

checkEndpointAvailability :: (InactiveEndpoints -> Bool) -> ServerM api ()
checkEndpointAvailability endpoint = whenM (asks (endpoint . envInactiveEndpoints)) $ throwM err404