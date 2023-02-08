{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TypeApplications    #-}

module Cardano.Server.Client.Opts where

import           Cardano.Server.Client.Class   (HasClient(..))
import           Control.Applicative           ((<|>))
import           Options.Applicative           (Parser, (<**>), auto, fullDesc, help, info, long, option, short, value,
                                                execParser, helper, flag', metavar, argument)

runWithOpts :: HasClient s => IO (Options s)
runWithOpts = execParser $ info (optionsParser <**> helper) fullDesc

optionsParser :: HasClient s => Parser (Options s)
optionsParser = Options <$> serverEndpointParser <*> (autoModeParser <|> manualModeParser)

data Options s = Options
    { optsEndpoint :: ServerEndpoint
    , optsMode     :: Mode s
    } deriving Show

data ServerEndpoint
    = Ping
    | NewTx
    | SubmitTx
    | ServerTx
    deriving (Read)

instance Show ServerEndpoint where
    show = \case
        Ping     -> "ping"
        NewTx    -> "newTx"
        SubmitTx -> "submitTx"
        ServerTx -> "serverTx"

serverEndpointParser :: Parser ServerEndpoint
serverEndpointParser = argument auto 
    (  value SubmitTx
    <> metavar "Ping | NewTx | SubmitTx | ServerTx" 
    )

data Mode s
    = Auto   Interval
    | Manual (ClientInput s)
deriving instance HasClient s => Show (Mode s)

--------------------------------------------- Auto ---------------------------------------------

type Interval = Int

autoModeParser :: Parser (Mode s)
autoModeParser
    = flag' Auto (long "auto") <*> intervalParser

intervalParser :: Parser Interval
intervalParser = option auto
    (  long  "interval"
    <> short 'i'
    <> help  "Average client request interval in seconds."
    <> value 30
    )

-------------------------------------------- Manual --------------------------------------------

manualModeParser :: forall s. HasClient s => Parser (Mode s)
manualModeParser = Manual <$> option (parseServerInput @s) (long "manual" <> help "Input of manual mode.")