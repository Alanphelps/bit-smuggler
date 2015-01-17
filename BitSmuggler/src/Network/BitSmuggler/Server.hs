{-# LANGUAGE RecordWildCards, TupleSections #-}
module Network.BitSmuggler.Server where

import Prelude as P hiding (read)
import Network.BitSmuggler.Crypto as Crypto
import System.Log.Logger
import Data.Word
import Control.Monad.Trans.Resource
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString as BS
import Control.Monad.IO.Class
import Data.IP
import Control.Monad
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TQueue
import Data.Time.Clock
import Data.Conduit as DC
import Data.Conduit.List as DC
import Data.Serialize as DS
import Data.LargeWord
import Crypto.Random
import Data.Tuple as Tup

import Network.TCP.Proxy.Server as Proxy hiding (UnsupportedFeature)
import Network.TCP.Proxy.Socks4 as Socks4

import Network.BitSmuggler.Common hiding (contactFiles)
import Network.BitSmuggler.Utils
import Network.BitSmuggler.Protocol
import Network.BitSmuggler.ARQ as ARQ

import Data.Map.Strict as Map

{-

SERVER.

run single torrent client - running many potentially blows the cover
 a normal peer in the bittorrent network runs a single instance of
 some torrent client

-}

logger = "BitSmuggler.Server"


data ServerConfig = ServerConfig {
    serverSecretKey :: Key
  , btClientConfig :: BTClientConfig
  -- the files on which the server is "listening"
  , contactFiles :: [ContactFile]
  , fileCachePath :: FilePath
}

data ServerState = ServerState {
    activeConns :: Map SessionToken Connection
}

data Connection = Conn {
    onHoldSince :: Maybe UTCTime
  , handlerTask :: Async ()
  , pieceHooks :: PieceHooks
  , controlPipe :: Pipe ClientMessage ServerMessage
  , allowData :: TMVar ()
}


listen :: ServerConfig -> (ConnData -> IO ()) -> IO ()
listen config handle = runResourceT $ do
  liftIO $ debugM logger "started bit-smuggler server..."

  let btConf = btClientConfig config
  -- start torrent client (with config)
  (btProc, btClientConn) <- setupBTClient $ btClientConfig config

  -- setup the files on which the client is working in a temp dir
  files <- setupContactFiles (contactFiles config) (fileCachePath config)
 
  serverState <- liftIO $ newTVarIO $ ServerState {activeConns = Map.empty}
  register $ cleanState serverState

  let fileFixer = findPieceLoader files
  let onConn = serverConnInit (serverSecretKey config) serverState handle fileFixer

  -- setup proxies

  (reverseProxy, forwardProxy) <- startProxies (btClientConfig config) onConn
  -- tell client to use the files
  -- TODO: implement

  -- wait for it...
  liftIO $ waitBoth (snd reverseProxy) (snd forwardProxy)
  return ()

-- server cleanup
cleanState stateVar = do
  state <- atomically $ readTVar stateVar
  forM (P.map snd $ Map.toList $ activeConns state) $ killConn
  return ()

killConn = cancel . handlerTask

-- TODO: check this out https://www.youtube.com/watch?v=uMK0prafzw0
serverConnInit secretKey stateVar handleConn fileFix direction local remote = do
  -- check if connection to this remote address is still active
  --maybeConn <- atomically $ fmap (Map.lookup remote . activeConns) $ readTVar stateVar
  pieceHs <- makePieceHooks

  forkIO $ handleConnection stateVar pieceHs secretKey handleConn

  streams <- fmap (if direction == Reverse then Tup.swap else P.id) $
                makeStreams pieceHs fileFix
  return $ DataHooks { incoming = P.fst streams
                     , outgoing = P.snd streams
                     , onDisconnect = return () -- TODO: implement 
                    } 


modActives f s = atomically $ modifyTVar s
  (\s -> s {activeConns = f $ activeConns s})


handleConnection stateVar pieceHooks secretKey userHandle = do
  -- classify connection 

  let noarq = noARQ -- there's no ARQ right now
  let packetSize = blockSize - Crypto.msgHeaderLen
  [fstClientMessage] <-
    runConduit $ (readSource (liftIO $ read $ recvPiece pieceHooks))
               =$ (recvPipe (recvARQ noarq) $ handshakeDecrypt secretKey) =$ DC.take 1
  case fstClientMessage of
    (ConnRequest keyRepr Nothing) -> do
      -- client is requesting the creation of a new session
      let crypto = makeServerEncryption secretKey keyRepr
      initCprg <- liftIO $ makeCPRG
      let (token, cprg) = cprgGenerate tokenLen initCprg
      let serverEncrypt = encrypter (encrypt crypto) cprg

      -- control messages   
      controlSend <-liftIO $ (newTQueueIO :: IO (TQueue ServerMessage))
      controlRecv <- liftIO $ (newTQueueIO :: IO (TQueue ClientMessage))

      let controlPipe = Pipe controlRecv controlSend
      allowData <- liftIO $ newEmptyTMVarIO

      task <- async $ runResourceT $ do
         register $ modActives (Map.delete token) stateVar
         runConnection packetSize pieceHooks noarq
                       serverEncrypt (decrypt crypto) token
                       userHandle controlPipe allowData
      modActives (Map.insert token (Conn Nothing task pieceHooks controlPipe allowData))
                 stateVar
      return ()     
    (ConnRequest keyRepr (Just token)) -> do
      -- client is requesting session recovery using token
      maybeConn <- atomically $ fmap (Map.lookup token . activeConns) $ readTVar stateVar
      case maybeConn of
        Just conn -> do
          -- TODO: implement session loading
          errorM logger "session loading not implemented!"
          throwIO UnsupportedFeature 
        Nothing -> do
          errorM logger "session token not found"
          throwIO ClientProtocolError
    _ -> do
        errorM logger "The first client message should always be a conn request"
        throwIO ClientProtocolError
  -- store conn  
  return ()

runConnection
  packetSize pieceHooks arq encrypter decrypt token userHandle control allowData = do
  user <- launchPipes packetSize pieceHooks arq encrypter decrypt control allowData
  -- reply to handshake 
  -- accept. we don't discriminate.. for now
  liftIO $ atomically $ writeTQueue (pipeSend control) $ AcceptConn token

  -- allowing data to flow
  liftIO $ atomically $ putTMVar allowData () 

  -- run conn handler
  liftIO $ userHandle $ ConnData {
                          connSend = atomically . writeTQueue (pipeSend user)
                        , connRecv = atomically $ readTQueue (pipeRecv user) }
  return ()

 
handshakeDecrypt sk bs = fmap P.snd $ tryReadHandshake sk $ bs

revProxy ip port = return $ ProxyAction {
                            command = CONNECT
                          , remoteAddr = (Right ip, port)
                          , onConnection = \ _ -> return () 
                          }

