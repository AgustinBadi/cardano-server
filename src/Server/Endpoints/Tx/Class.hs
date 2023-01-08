{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE UndecidableSuperClasses    #-}

module Server.Endpoints.Tx.Class where

import           Control.Monad.Catch              (Exception)
import           Control.Monad.Reader             (MonadReader)
import           Data.Aeson                       (ToJSON)
import           Data.Kind                        (Type)
import           Data.Text                        (Text)
import           GHC.Generics                     (Generic)
import           IO.Wallet                        (HasWallet(..))
import           Servant                          (NoContent(..), Union, IsMember, WithStatus, HasStatus)
import           Server.Class                     (AppM, HasServer(..), Env)
import           Types.Tx                         (TransactionBuilder)

class ( HasServer s
      , IsMember NoContent             (TxApiResultOf s)
      , IsMember NewTxEndpointResult   (TxApiResultOf s)
      , IsMember (WithStatus 422 Text) (TxApiResultOf s)
      , Show (TxEndpointsErrorOf s)
      , Exception (TxEndpointsErrorOf s)
      ) => HasTxEndpoints s where

    type TxApiResultOf s :: [Type]

    data TxEndpointsErrorOf s

    txEndpointsTxBuilders :: (MonadReader (Env s) m, HasWallet m) => InputOf s -> m [TransactionBuilder ()]

    checkForTxEndpointsErrors :: InputOf s -> AppM s ()

    txEndpointsErrorHandler :: TxEndpointsErrorOf s -> AppM s (Union (TxApiResultOf s))

type DefaultTxApiResult = '[WithStatus 422 Text, NoContent, NewTxEndpointResult]

newtype NewTxEndpointResult = NewTxEndpointResult Text
    deriving HasStatus via WithStatus 200 NewTxEndpointResult
    deriving (Show, Generic)
    deriving newtype ToJSON 