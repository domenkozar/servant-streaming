{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE UndecidableInstances #-}
module Servant.Streaming.Server.Internal where

import           Control.Exception                          (bracket)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Resource               (ResourceT,
                                                             InternalState,
                                                             createInternalState,
                                                             closeInternalState,
                                                             runInternalState)
import qualified Data.ByteString                            as BS
import           Data.Maybe                                 (fromMaybe)
import           GHC.TypeLits                               (KnownNat, natVal)
import qualified Network.HTTP.Media                         as M
import           Network.HTTP.Types                         (Method, Status,
                                                             hAccept,
                                                             hContentType)
import           Network.Wai                                (Response,
                                                             requestHeaders)
import           Network.Wai.Streaming                      (streamingRequest,
                                                             streamingResponse)
import           Servant                                    hiding (Stream)
import           Servant.API.ContentTypes                   (AllMime (allMime))
import           Servant.API.ResponseHeaders                (GetHeaders')
import           Servant.Server.Internal                    (ct_wildcard,
                                                             methodCheck,
                                                             acceptCheck)
import           Servant.Server.Internal.Router             (leafRouter)
import           Servant.Server.Internal.RoutingApplication (DelayedIO,
                                                             RouteResult (Route),
                                                             addBodyCheck,
                                                             addMethodCheck,
                                                             addAcceptCheck,
                                                             delayedFailFatal,
                                                             runAction,
                                                             withRequest)
import           Servant.Streaming
import           Streaming

instance ( AllMime contentTypes, HasServer subapi ctx, MonadIO n
         ) => HasServer (StreamBodyMonad contentTypes n :> subapi) ctx where
  type ServerT (StreamBodyMonad contentTypes n :> subapi) m
    = (M.MediaType, Stream (Of BS.ByteString) (ResourceT n) ())
      -> ServerT subapi m

  route _ ctxt subapi =
    route (Proxy :: Proxy subapi) ctxt
      $ addBodyCheck subapi getContentType makeBody
      where
        getContentType :: DelayedIO M.MediaType
        getContentType = withRequest $ \request -> do
          let contentTypeHdr
               = fromMaybe ("application" M.// "octet-stream")
               $ lookup hContentType (requestHeaders request) >>= M.parseAccept
          if contentTypeHdr `elem` contentTypeList
            then return contentTypeHdr else delayedFailFatal err415

        contentTypeList :: [M.MediaType]
        contentTypeList = allMime (Proxy :: Proxy contentTypes)

        makeBody :: MonadIO m => a -> DelayedIO (a, Stream (Of BS.ByteString) m ())
        makeBody a = withRequest $ \req -> return (a, streamingRequest req)

  hoistServerWithContext _ a b c
    = hoistServerWithContext (Proxy :: Proxy subapi) a b . c


instance ( KnownNat status, AllMime contentTypes, ReflectMethod method
         ) => HasServer (StreamResponse method status contentTypes) ctx where
  type ServerT (StreamResponse method status contentTypes) m
    = m (Stream (Of BS.ByteString) (ResourceT IO) ())

  hoistServerWithContext _ _ b c = b c
  route _ _ subapi = streamRouter ([],) subapi contentTypeProxy statusProxy method
    where
      contentTypeProxy :: Proxy contentTypes
      contentTypeProxy = Proxy

      statusProxy :: Proxy status
      statusProxy = Proxy

      method :: Method
      method = reflectMethod (Proxy :: Proxy method)


instance ( KnownNat status, AllMime contentTypes, ReflectMethod method, GetHeaders' hs
         ) => HasServer (Headers hs (StreamResponse method status contentTypes)) ctx where
  type ServerT (Headers hs (StreamResponse method status contentTypes)) m
    = m (Headers hs (Streaming.Stream (Of BS.ByteString) (ResourceT IO) ()))

  hoistServerWithContext _ _ nt s = nt s
  route _ _ subapi = streamRouter (\x -> (getHeaders x, getResponse x)) subapi contentTypeProxy statusProxy method
    where
      contentTypeProxy :: Proxy contentTypes
      contentTypeProxy = Proxy

      method :: Method
      method = reflectMethod (Proxy :: Proxy method)

      statusProxy :: Proxy status
      statusProxy = Proxy


-- streamRouter :: _
streamRouter headersAndResponse subapi contentTypeProxy statusProxy method =
  leafRouter $ \env request respond ->
    let
        accept = fromMaybe ct_wildcard $ lookup hAccept $ requestHeaders request
        action = subapi `addMethodCheck` methodCheck method request
                        `addAcceptCheck` acceptCheck contentTypeProxy accept
    in bracket createInternalState
               closeInternalState
               (runAction action env request respond . streamResponse)
    where
      -- streamResponse :: InternalState -> _ -> RouteResult Response
      streamResponse st output =
        Route $ streamingResponse (hoist (`runInternalState` st) stream) status headers
        where
          (headers, stream) = headersAndResponse output

      status :: Status
      status = toEnum $ fromInteger $ natVal statusProxy
