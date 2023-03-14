{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

module Cardano.Server.Example.Main
    ( ExampleApi
    , runExampleServer
    ) where

import           Cardano.Server.Error.Class      (IsCardanoServerError (..))
import           Cardano.Server.Example.OffChain (testMintTx)
import           Cardano.Server.Input            (InputContext)
import           Cardano.Server.Internal         (InputOf, defaultServerTrackedAddresses)
import           Cardano.Server.Main             (ServerApi, runServer)
import           Control.Monad.Catch             (Exception)
import           Plutus.V2.Ledger.Api            (BuiltinByteString)
import           PlutusAppsExtra.IO.ChainIndex   (ChainIndex (..))

type ExampleApi = ServerApi ([BuiltinByteString], InputContext) ExampleApiError

type instance InputOf ExampleApi = [BuiltinByteString]

data ExampleApiError = HasDuplicates
    deriving (Show, Exception)

instance IsCardanoServerError ExampleApiError where
    errStatus _ = toEnum 422
    errMsg _ = "The request contains duplicate tokens and will not be processed."

runExampleServer :: IO ()
runExampleServer = runServer
    @ExampleApi
    Kupo
    defaultServerTrackedAddresses
    (\bbs -> pure [testMintTx bbs])
    (pure ())
    pure

-- data ExampleServer

-- instance HasServer ExampleServer where

--     type AuxiliaryEnvOf ExampleServer = ()

--     loadAuxiliaryEnv _ = pure ()

--     type InputOf ExampleServer = [BuiltinByteString]

-- instance HasTxEndpoints ExampleServer where

--     type TxApiRequestOf ExampleServer = InputWithContext ExampleServer

--     data (TxEndpointsErrorOf ExampleServer) = HasDuplicates
--         deriving (Show, Exception)

--     txEndpointsProcessRequest req@(bbs, _) = do
--         let hasDuplicates = length bbs /= length (nub bbs)
--         when hasDuplicates $ throwM HasDuplicates
--         return req

--     txEndpointsTxBuilders bbs = pure [testMintTx bbs]

