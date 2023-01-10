{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MagicHash             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UnboxedTuples         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE UnliftedFFITypes      #-}

-- |
-- Module      : Streaming.ByteString.Internal
-- Copyright   : (c) Don Stewart 2006
--               (c) Duncan Coutts 2006-2011
--               (c) Michael Thompson 2015
-- License     : BSD-style

module Streaming.ByteString.Internal
  ( ByteStream(..)
  , ByteString
  , consChunk
  , chunkOverhead
  , defaultChunkSize
  , materialize
  , dematerialize
  , foldrChunks
  , foldlChunks

  , foldrChunksM
  , foldlChunksM
  , chunkFold
  , chunkFoldM
  , chunkMap
  , chunkMapM
  , chunkMapM_
  , unfoldMChunks
  , unfoldrChunks

  , packChars
  , packBytes
  , unpackBytes
  , chunk
  , smallChunkSize
  , mwrap
  , unfoldrNE
  , reread
  , unsafeLast
  , unsafeInit
  , copy
  , findIndexOrEnd

    -- * ResourceT help
  , bracketByteString

    -- * Re-export from GHC 9.0
  , unsafeWithForeignPtr
  ) where

import           Control.Monad
import           Control.Monad.Morph
import           Control.Monad.Trans
import           Prelude hiding
    (all, any, appendFile, break, concat, concatMap, cycle, drop, dropWhile,
    elem, filter, foldl, foldl1, foldr, foldr1, getContents, getLine, head,
    init, interact, iterate, last, length, lines, map, maximum, minimum,
    notElem, null, putStr, putStrLn, readFile, repeat, replicate, reverse,
    scanl, scanl1, scanr, scanr1, span, splitAt, tail, take, takeWhile,
    unlines, unzip, writeFile, zip, zipWith)
import qualified Prelude

#if !MIN_VERSION_base(4,11,0)
import           Data.Semigroup
#endif

import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B

import           Streaming (Of(..))
import           Streaming.Internal hiding (concats)
import qualified Streaming.Prelude as SP

import           Data.String
import           Foreign.Ptr
import           Foreign.Storable
import           GHC.Types (SPEC(..))

import           Data.Functor.Identity
import           Data.Word
import           GHC.Base (realWorld#)
import           GHC.IO (IO(IO))
import           System.IO.Unsafe (unsafePerformIO)

import           Control.Monad.Base
import           Control.Monad.Catch (MonadCatch(..))
import           Control.Monad.Trans.Resource

#if MIN_VERSION_base(4,15,0)
import           GHC.ForeignPtr (unsafeWithForeignPtr)
#else
import           Foreign.ForeignPtr (ForeignPtr, withForeignPtr)
#endif

#if !MIN_VERSION_base(4,15,0)
-- | Synonym of 'withForeignPtr' for GHC prior to 9.0.
unsafeWithForeignPtr :: ForeignPtr a -> (Ptr a -> IO b) -> IO b
unsafeWithForeignPtr = withForeignPtr
#endif

-- | A type alias for back-compatibility.
type ByteString = ByteStream
{-# DEPRECATED ByteString "Use ByteStream instead." #-}

-- | A space-efficient representation of a succession of 'Word8' vectors,
-- supporting many efficient operations.
--
-- An effectful 'ByteStream' contains 8-bit bytes, or by using the operations
-- from "Streaming.ByteString.Char8" it can be interpreted as containing
-- 8-bit characters.
data ByteStream m r =
  Empty r
  | Chunk {-# UNPACK #-} !B.ByteString (ByteStream m r )
  | Go (m (ByteStream m r ))

instance Monad m => Functor (ByteStream m) where
  fmap f x = case x of
    Empty a      -> Empty (f a)
    Chunk bs bss -> Chunk bs (fmap f bss)
    Go mbss      -> Go (fmap (fmap f) mbss)

instance Monad m => Applicative (ByteStream m) where
  pure = Empty
  {-# INLINE pure #-}
  bf <*> bx = do {f <- bf; x <- bx; Empty (f x)}
  {-# INLINE (<*>) #-}
  x0 *> y = loop SPEC x0 where
    loop !_ x = case x of   -- this seems to be insanely effective
      Empty _   -> y
      Chunk a b -> Chunk a (loop SPEC b)
      Go m      -> Go (fmap (loop SPEC) m)
  {-# INLINEABLE (*>) #-}

instance Monad m => Monad (ByteStream m) where
  return = pure
  {-# INLINE return #-}
  (>>) = (*>)
  {-# INLINE (>>) #-}
  x >>= f =
    -- case x of
    --   Empty a -> f a
    --   Chunk bs bss -> Chunk bs (bss >>= f)
    --   Go mbss      -> Go (fmap (>>= f) mbss)
    loop SPEC2 x where -- unlike >> this SPEC seems pointless
      loop !_ y = case y of
        Empty a      -> f a
        Chunk bs bss -> Chunk bs (loop SPEC bss)
        Go mbss      -> Go (fmap (loop SPEC) mbss)
  {-# INLINEABLE (>>=) #-}

instance MonadIO m => MonadIO (ByteStream m) where
  liftIO io = Go (fmap Empty (liftIO io))
  {-# INLINE liftIO #-}

instance MonadTrans ByteStream where
  lift ma = Go $ fmap Empty ma
  {-# INLINE lift #-}

instance MFunctor ByteStream where
  hoist phi bs = case bs of
    Empty r        -> Empty r
    Chunk bs' rest -> Chunk bs' (hoist phi rest)
    Go m           -> Go (phi (fmap (hoist phi) m))
  {-# INLINABLE hoist #-}

instance (r ~ ()) => IsString (ByteStream m r) where
  fromString = chunk . B.pack . Prelude.map B.c2w
  {-# INLINE fromString #-}

instance (m ~ Identity, Show r) => Show (ByteStream m r) where
  show bs0 = case bs0 of  -- the implementation this instance deserves ...
    Empty r           -> "Empty (" ++ show r ++ ")"
    Go (Identity bs') -> "Go (Identity (" ++ show bs' ++ "))"
    Chunk bs'' bs     -> "Chunk " ++ show bs'' ++ " (" ++ show bs ++ ")"

instance (Semigroup r, Monad m) => Semigroup (ByteStream m r) where
  (<>) = liftM2 (<>)
  {-# INLINE (<>) #-}

instance (Monoid r, Monad m) => Monoid (ByteStream m r) where
  mempty = Empty mempty
  {-# INLINE mempty #-}
#if MIN_VERSION_base(4,11,0)
  mappend = (<>)
#else
  mappend = liftM2 mappend
#endif
  {-# INLINE mappend #-}

instance (MonadBase b m) => MonadBase b (ByteStream m) where
  liftBase  = mwrap . fmap return . liftBase
  {-# INLINE liftBase #-}

instance (MonadThrow m) => MonadThrow (ByteStream m) where
  throwM = lift . throwM
  {-# INLINE throwM #-}

instance (MonadCatch m) => MonadCatch (ByteStream m) where
  catch str f = go str
    where
    go p = case p of
      Chunk bs rest  -> Chunk bs (go rest)
      Empty  r       -> Empty r
      Go  m          -> Go (catch (do
          p' <- m
          return (go p'))
       (return . f))
  {-# INLINABLE catch #-}

instance (MonadResource m) => MonadResource (ByteStream m) where
  liftResourceT = lift . liftResourceT
  {-# INLINE liftResourceT #-}

-- | Like @bracket@, but specialized for `ByteString`.
bracketByteString :: MonadResource m => IO a -> (a -> IO ()) -> (a -> ByteStream m b) -> ByteStream m b
bracketByteString alloc free inside = do
        (key, seed) <- lift (allocate alloc free)
        clean key (inside seed)
  where
    clean key = loop where
      loop str = case str of
        Empty r       -> Go (release key >> return (Empty r))
        Go m          -> Go (fmap loop m)
        Chunk bs rest -> Chunk bs (loop rest)
{-# INLINABLE bracketByteString #-}

-- -- ------------------------------------------------------------------------
--
-- | Smart constructor for 'Chunk'.
consChunk :: B.ByteString -> ByteStream m r -> ByteStream m r
consChunk c@(B.PS _ _ len) cs
  | len == 0  = cs
  | otherwise = Chunk c cs
{-# INLINE consChunk #-}

-- | Yield-style smart constructor for 'Chunk'.
chunk :: B.ByteString -> ByteStream m ()
chunk bs = consChunk bs (Empty ())
{-# INLINE chunk #-}


{- | Reconceive an effect that results in an effectful bytestring as an effectful bytestring.
    Compare Streaming.mwrap. The closest equivalent of

>>> Streaming.wrap :: f (Stream f m r) -> Stream f m r

    is here  @consChunk@. @mwrap@ is the smart constructor for the internal @Go@ constructor.
-}
mwrap :: m (ByteStream m r) -> ByteStream m r
mwrap = Go
{-# INLINE mwrap #-}

-- | Construct a succession of chunks from its Church encoding (compare @GHC.Exts.build@)
materialize :: (forall x . (r -> x) -> (B.ByteString -> x -> x) -> (m x -> x) -> x) -> ByteStream m r
materialize phi = phi Empty Chunk Go
{-# INLINE[0] materialize #-}

-- | Resolve a succession of chunks into its Church encoding; this is
-- not a safe operation; it is equivalent to exposing the constructors
dematerialize :: Monad m
              => ByteStream m r
              -> (forall x . (r -> x) -> (B.ByteString -> x -> x) -> (m x -> x) -> x)
dematerialize x0 nil cons mwrap' = loop SPEC x0
  where
  loop !_ x = case x of
     Empty r    -> nil r
     Chunk b bs -> cons b (loop SPEC bs )
     Go ms      -> mwrap' (fmap (loop SPEC) ms)
{-# INLINE [1] dematerialize #-}

{-# RULES
  "dematerialize/materialize" forall (phi :: forall b . (r -> b) -> (B.ByteString -> b -> b) -> (m b -> b)  -> b). dematerialize (materialize phi) = phi ;
  #-}
------------------------------------------------------------------------

-- The representation uses lists of packed chunks. When we have to convert from
-- a lazy list to the chunked representation, then by default we use this
-- chunk size. Some functions give you more control over the chunk size.
--
-- Measurements here:
--  http://www.cse.unsw.edu.au/~dons/tmp/chunksize_v_cache.png
--
-- indicate that a value around 0.5 to 1 x your L2 cache is best.
-- The following value assumes people have something greater than 128k,
-- and need to share the cache with other programs.

-- | The chunk size used for I\/O. Currently set to 32k, less the memory management overhead
defaultChunkSize :: Int
defaultChunkSize = 32 * k - chunkOverhead
   where k = 1024
{-# INLINE defaultChunkSize #-}
-- | The recommended chunk size. Currently set to 4k, less the memory management overhead
smallChunkSize :: Int
smallChunkSize = 4 * k - chunkOverhead
   where k = 1024
{-# INLINE smallChunkSize #-}

-- | The memory management overhead. Currently this is tuned for GHC only.
chunkOverhead :: Int
chunkOverhead = 2 * sizeOf (undefined :: Int)
{-# INLINE chunkOverhead #-}

-- | Packing and unpacking from lists
-- packBytes' :: Monad m => [Word8] -> ByteString m ()
-- packBytes' cs0 =
--     packChunks 32 cs0
--   where
--     packChunks n cs = case B.packUptoLenBytes n cs of
--       (bs, [])  -> Chunk bs (Empty ())
--       (bs, cs') -> Chunk bs (packChunks (min (n * 2) BI.smallChunkSize) cs')
--     -- packUptoLenBytes :: Int -> [Word8] -> (ByteString, [Word8])
--     packUptoLenBytes len xs0 =
--         accursedUnutterablePerformIO (createUptoN' len $ \p -> go p len xs0)
--       where
--         go !_ !n []     = return (len-n, [])
--         go !_ !0 xs     = return (len,   xs)
--         go !p !n (x:xs) = poke p x >> go (p `plusPtr` 1) (n-1) xs
--         createUptoN' :: Int -> (Ptr Word8 -> IO (Int, a)) -> IO (B.ByteString, a)
--         createUptoN' l f = do
--             fp <- B.mallocByteString l
--             (l', res) <- withForeignPtr fp $ \p -> f p
--             assert (l' <= l) $ return (B.PS fp 0 l', res)
-- {-# INLINABLE packBytes' #-}

-- | Convert a `Stream` of pure `Word8` into a chunked 'ByteStream'.
packBytes :: Monad m => Stream (Of Word8) m r -> ByteStream m r
packBytes cs0 = do
  -- XXX: Why 32?  It seems like a rather small chunk size, wouldn't
  -- smallChunkSize make a better choice?
  (bytes :> rest) <- lift $ SP.toList $ SP.splitAt 32 cs0
  case bytes of
    [] -> case rest of
      Return r -> Empty r
      Step as  -> packBytes (Step as)  -- these two pattern matches
      Effect m -> Go $ fmap packBytes m -- should be avoided.
    _  -> Chunk (B.packBytes bytes) (packBytes rest)
{-# INLINABLE packBytes #-}

-- | Convert a vanilla `Stream` of characters into a stream of bytes.
--
-- /Note:/ Each `Char` value is truncated to 8 bits.
packChars :: Monad m => Stream (Of Char) m r -> ByteStream m r
packChars str = do
  -- XXX: Why 32?  It seems like a rather small chunk size, wouldn't
  -- smallChunkSize make a better choice?
  --
  -- We avoid the cost of converting the stream of Chars to a stream
  -- of Word8 (passed to packBytes), and instead pass the original
  -- `Char` arrays to 'B.packChars', which will be more efficient,
  -- the conversion there will be essentially free.
  (chars :> rest) <- lift $ SP.toList $ SP.splitAt 32 str
  case chars of
    [] -> case rest of
      Return r -> Empty r
      Step as  -> packChars (Step as)  -- these two pattern matches
      Effect m -> Go $ fmap packChars m -- should be avoided.
    _  -> Chunk (B.packChars chars) (packChars rest)
{-# INLINABLE packChars #-}

-- | The reverse of `packChars`. Given a stream of bytes, produce a `Stream`
-- individual bytes.
unpackBytes :: Monad m => ByteStream m r -> Stream (Of Word8) m r
unpackBytes bss = dematerialize bss Return unpackAppendBytesLazy Effect
  where
  unpackAppendBytesLazy :: B.ByteString -> Stream (Of Word8) m r -> Stream (Of Word8) m r
  unpackAppendBytesLazy b@(B.PS fp off len) xs
    | len <= 100 = unpackAppendBytesStrict b xs
    | otherwise  = unpackAppendBytesStrict (B.PS fp off 100) remainder
    where
      remainder  = unpackAppendBytesLazy (B.PS fp (off+100) (len-100)) xs

  unpackAppendBytesStrict :: B.ByteString -> Stream (Of Word8) m r -> Stream (Of Word8) m r
  unpackAppendBytesStrict (B.PS fp off len) xs =
    B.accursedUnutterablePerformIO $ unsafeWithForeignPtr fp $ \base ->
      loop (base `plusPtr` (off-1)) (base `plusPtr` (off-1+len)) xs
    where
      loop !sentinel !p acc
        | p == sentinel = return acc
        | otherwise     = do
            x <- peek p
            loop sentinel (p `plusPtr` (-1)) (Step (x :> acc))
{-# INLINABLE unpackBytes #-}

-- | Copied from Data.ByteString.Unsafe for compatibility with older bytestring.
unsafeLast :: B.ByteString -> Word8
unsafeLast (B.PS x s l) =
    accursedUnutterablePerformIO $ unsafeWithForeignPtr x $ \p -> peekByteOff p (s+l-1)
 where
      accursedUnutterablePerformIO (IO m) = case m realWorld# of (# _, r #) -> r
{-# INLINE unsafeLast #-}

-- | Copied from Data.ByteString.Unsafe for compatibility with older bytestring.
unsafeInit :: B.ByteString -> B.ByteString
unsafeInit (B.PS ps s l) = B.PS ps s (l-1)
{-# INLINE unsafeInit #-}

-- | Consume the chunks of an effectful `ByteString` with a natural right fold.
foldrChunks :: Monad m => (B.ByteString -> a -> a) -> a -> ByteStream m r -> m a
foldrChunks step nil bs = dematerialize bs
  (\_ -> return nil)
  (fmap . step)
  join
{-# INLINE foldrChunks #-}

-- | Consume the chunks of an effectful `ByteString` with a left fold. Suitable
-- for use with `SP.mapped`.
foldlChunks :: Monad m => (a -> B.ByteString -> a) -> a -> ByteStream m r -> m (Of a r)
foldlChunks f z = go z
  where go a _            | a `seq` False = undefined
        go a (Empty r)    = return (a :> r)
        go a (Chunk c cs) = go (f a c) cs
        go a (Go m)       = m >>= go a
{-# INLINABLE foldlChunks #-}

-- | Instead of mapping over each `Word8` or `Char`, map over each strict
-- `B.ByteString` chunk in the stream.
chunkMap :: Monad m => (B.ByteString -> B.ByteString) -> ByteStream m r -> ByteStream m r
chunkMap f bs = dematerialize bs return (Chunk . f) Go
{-# INLINE chunkMap #-}

-- | Like `chunkMap`, but map effectfully.
chunkMapM :: Monad m => (B.ByteString -> m B.ByteString) -> ByteStream m r -> ByteStream m r
chunkMapM f bs = dematerialize bs return (\bs' bss -> Go (fmap (`Chunk` bss) (f bs'))) Go
{-# INLINE chunkMapM #-}

-- | Like `chunkMapM`, but discard the result of each effectful mapping.
chunkMapM_ :: Monad m => (B.ByteString -> m x) -> ByteStream m r -> m r
chunkMapM_ f bs = dematerialize bs return (\bs' mr -> f bs' >> mr) join
{-# INLINE chunkMapM_ #-}

-- | @chunkFold@ is preferable to @foldlChunks@ since it is an appropriate
-- argument for @Control.Foldl.purely@ which permits many folds and sinks to be
-- run simultaneously on one bytestream.
chunkFold :: Monad m => (x -> B.ByteString -> x) -> x -> (x -> a) -> ByteStream m r -> m (Of a r)
chunkFold step begin done = go begin
  where go a _            | a `seq` False = undefined
        go a (Empty r)    = return (done a :> r)
        go a (Chunk c cs) = go (step a c) cs
        go a (Go m)       = m >>= go a
{-# INLINABLE chunkFold #-}

-- | 'chunkFoldM' is preferable to 'foldlChunksM' since it is an appropriate
-- argument for 'Control.Foldl.impurely' which permits many folds and sinks to
-- be run simultaneously on one bytestream.
chunkFoldM :: Monad m => (x -> B.ByteString -> m x) -> m x -> (x -> m a) -> ByteStream m r -> m (Of a r)
chunkFoldM step begin done bs = begin >>= go bs
  where
    go str !x = case str of
      Empty r    -> done x >>= \a -> return (a :> r)
      Chunk c cs -> step x c >>= go cs
      Go m       -> m >>= \str' -> go str' x
{-# INLINABLE chunkFoldM  #-}

-- | Like `foldlChunks`, but fold effectfully. Suitable for use with `SP.mapped`.
foldlChunksM :: Monad m => (a -> B.ByteString -> m a) -> m a -> ByteStream m r -> m (Of a r)
foldlChunksM f z bs = z >>= \a -> go a bs
  where
    go !a str = case str of
      Empty r    -> return (a :> r)
      Chunk c cs -> f a c >>= \aa -> go aa cs
      Go m       -> m >>= go a
{-# INLINABLE foldlChunksM #-}

-- | Consume the chunks of an effectful ByteString with a natural right monadic fold.
foldrChunksM :: Monad m => (B.ByteString -> m a -> m a) -> m a -> ByteStream m r -> m a
foldrChunksM step nil bs = dematerialize bs (const nil) step join
{-# INLINE foldrChunksM #-}

-- | Internal utility for @unfoldr@.
unfoldrNE :: Int -> (a -> Either r (Word8, a)) -> a -> (B.ByteString, Either r a)
unfoldrNE i f x0
    | i < 0     = (B.empty, Right x0)
    | otherwise = unsafePerformIO $ B.createAndTrim' i $ \p -> go p x0 0
  where
    go !p !x !n
      | n == i    = return (0, n, Right x)
      | otherwise = case f x of
                      Left r     -> return (0, n, Left r)
                      Right (w,x') -> do poke p w
                                         go (p `plusPtr` 1) x' (n+1)
{-# INLINE unfoldrNE #-}

-- | Given some continual monadic action that produces strict `B.ByteString`
-- chunks, produce a stream of bytes.
unfoldMChunks :: Monad m => (s -> m (Maybe (B.ByteString, s))) -> s -> ByteStream m ()
unfoldMChunks step = loop where
  loop s = Go $ do
    m <- step s
    case m of
      Nothing      -> return (Empty ())
      Just (bs,s') -> return $ Chunk bs (loop s')
{-# INLINABLE unfoldMChunks #-}

-- | Like `unfoldMChunks`, but feed through a final @r@ return value.
unfoldrChunks :: Monad m => (s -> m (Either r (B.ByteString, s))) -> s -> ByteStream m r
unfoldrChunks step = loop where
  loop !s = Go $ do
    m <- step s
    case m of
      Left r        -> return (Empty r)
      Right (bs,s') -> return $ Chunk bs (loop s')
{-# INLINABLE unfoldrChunks #-}

-- | Stream chunks from something that contains @m (Maybe ByteString)@ until it
-- returns 'Nothing'. 'reread' is of particular use rendering @io-streams@ input
-- streams as byte streams in the present sense.
--
-- > import qualified Data.ByteString as B
-- > import qualified System.IO.Streams as S
-- > Q.reread S.read            :: S.InputStream B.ByteString -> Q.ByteStream IO ()
-- > Q.reread (liftIO . S.read) :: MonadIO m => S.InputStream B.ByteString -> Q.ByteStream m ()
--
-- The other direction here is
--
-- > S.unfoldM Q.unconsChunk    :: Q.ByteString IO r -> IO (S.InputStream B.ByteString)
reread :: Monad m => (s -> m (Maybe B.ByteString)) -> s -> ByteStream m ()
reread step s = loop where
  loop = Go $ do
    m <- step s
    case m of
      Nothing -> return (Empty ())
      Just a  -> return (Chunk a loop)
{-# INLINEABLE reread #-}

{-| Make the information in a bytestring available to more than one eliminating fold, e.g.

>>>  Q.count 'l' $ Q.count 'o' $ Q.copy $ "hello\nworld"
3 :> (2 :> ())

>>> Q.length $ Q.count 'l' $ Q.count 'o' $ Q.copy $ Q.copy "hello\nworld"
11 :> (3 :> (2 :> ()))

>>> runResourceT $ Q.writeFile "hello2.txt" $ Q.writeFile "hello1.txt" $ Q.copy $ "hello\nworld\n"
>>> :! cat hello2.txt
hello
world
>>> :! cat hello1.txt
hello
world

    This sort of manipulation could as well be acheived by combining folds - using
    @Control.Foldl@ for example. But any sort of manipulation can be involved in
    the fold.  Here are a couple of trivial complications involving splitting by lines:

>>> let doubleLines = Q.unlines . maps (<* Q.chunk "\n" ) . Q.lines
>>> let emphasize = Q.unlines . maps (<* Q.chunk "!" ) . Q.lines
>>> runResourceT $ Q.writeFile "hello2.txt" $ emphasize $ Q.writeFile "hello1.txt" $ doubleLines $ Q.copy $ "hello\nworld"
>>> :! cat hello2.txt
hello!
world!
>>> :! cat hello1.txt
hello
<BLANKLINE>
world
<BLANKLINE>

    As with the parallel operations in @Streaming.Prelude@, we have

> Q.effects . Q.copy       = id
> hoist Q.effects . Q.copy = id

   The duplication does not by itself involve the copying of bytestring chunks;
   it just makes two references to each chunk as it arises. This does, however
   double the number of constructors associated with each chunk.

-}
copy :: Monad m => ByteStream m r -> ByteStream (ByteStream m) r
copy = loop where
  loop str = case str of
    Empty r       -> Empty r
    Go m          -> Go (fmap loop (lift m))
    Chunk bs rest -> Chunk bs (Go (Chunk bs (Empty (loop rest))))
{-# INLINABLE copy #-}

-- | 'findIndexOrEnd' is a variant of findIndex, that returns the length of the
-- string if no element is found, rather than Nothing.
findIndexOrEnd :: (Word8 -> Bool) -> B.ByteString -> Int
findIndexOrEnd k (B.PS x s l) =
    B.accursedUnutterablePerformIO $
      unsafeWithForeignPtr x $ \f -> go (f `plusPtr` s) 0
  where
    go !ptr !n | n >= l    = return l
               | otherwise = do w <- peek ptr
                                if k w
                                  then return n
                                  else go (ptr `plusPtr` 1) (n+1)
{-# INLINABLE findIndexOrEnd #-}
