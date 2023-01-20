{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}

module Cardano.Server.Endpoints.Tx.New where

import           Cardano.Server.Endpoints.Tx.Class    (HasTxEndpoints(..))
import           Cardano.Server.Error                 (ConnectionError, Envelope, Throws, IsCardanoServerError(..),
                                                       ExceptionDeriving(..), toEnvelope)
import           Cardano.Server.Internal              (NetworkM, HasServer(..))
import           Cardano.Server.Tx                    (mkBalanceTx, MkTxError)
import           Cardano.Server.Utils.Logger          (HasLogger(..), (.<))
import           Control.Monad                        (join, liftM3)
import           Control.Monad.Catch                  (Exception, MonadThrow (throwM))
import           Data.Aeson                           (ToJSON)
import           Data.Text                            (Text)
import           GHC.Generics                         (Generic)
import           Ledger                               (CardanoTx)
import           Servant                              (JSON, (:>), ReqBody, Post)
import           Utils.Tx                             (cardanoTxToText)

type NewTxApi s = "newTx"
              :> Throws NewTxApiError
              :> Throws ConnectionError
              :> Throws MkTxError
              :> ReqBody '[JSON] (TxApiRequestOf s)
              :> Post '[JSON] Text

newtype NewTxApiError = UnserialisableCardanoTx CardanoTx
    deriving (Show, Generic, ToJSON)
    deriving Exception via (ExceptionDeriving NewTxApiError)

instance IsCardanoServerError NewTxApiError where
    errStatus _ = toEnum 422
    errMsg (UnserialisableCardanoTx tx) = "Cannot serialise balanced tx:" .< tx

newTxHandler :: forall s. HasTxEndpoints s 
    => TxApiRequestOf s
    -> NetworkM s (Envelope '[NewTxApiError, ConnectionError, MkTxError] Text)
newTxHandler req = toEnvelope $ do
    logMsg $ "New newTx request received:\n" .< req
    (input, context) <- txEndpointsProcessRequest req
    balancedTx <- join $ liftM3 mkBalanceTx (serverTrackedAddresses @s) (pure context) (txEndpointsTxBuilders @s input)
    case cardanoTxToText balancedTx of
        Just res -> pure res
        Nothing -> throwM $ UnserialisableCardanoTx balancedTx