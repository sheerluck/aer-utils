

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MonadComprehensions #-}

module IntegralBased  where

import           Data.Number.Erf
import           Data.List
import           Data.Binary
import           Data.Thyme
import           Data.Foldable

import           System.Directory
import           System.Locale

import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Generic as G
{-import qualified Data.Vector.Unboxed as U-}
import           Linear


import           Control.Monad
import           Control.Monad.Random
import           Control.Parallel.Strategies

import           Debug.Trace

import           Orphans

import qualified Numeric.LinearAlgebra as LA
import           Numeric.GSL.Integration
import           Numeric.GSL.Minimization


type Event a  = V3 a
type Events a = V.Vector (Event a)

type Patch a = Events a
type Phi a   = Events a
type As a    = V.Vector a

type Patches a = V.Vector (Patch a)
type Phis a    = V.Vector (Phi a)


-- | this function calculates a set of coefficients that
-- | scales the given phis to match the given patch best
-- | this is done by a gradient descent over the error
-- | function below
gradientDescentToFindAs :: Patch Double -> Phis Double -> As Double -> S.Vector Double
gradientDescentToFindAs patch phis randomAs = fst $ minimizeV NMSimplex2 10e-9 1000 (S.replicate (length phis) 1) (\v -> asError patch phis (V.convert v)) (V.convert randomAs)

-- | distance between several spike trains
asError :: Patch Double -> Phis Double -> As Double -> Double
asError patch phis coeffs = realIntegral' (V.toList (phis' V.++ patches')) (-1000) 1000 --(V3 0 0 (-10)) (V3 128 128 10)
    where phis'    = foldl (V.++) V.empty  $ V.zipWith (\a phi -> addAs a phi) coeffs phis
          patches' = addAs (-1) patch

-- | find closest spike in the gradient field spanned by the patches
findClosestPatchSpike :: Patch Double -> V3 Double -> (S.Vector Double, LA.Matrix Double)
findClosestPatchSpike patch v = minimizeV NMSimplex2 1e-6 1000 (S.replicate 3 1) go (unpackV3 v)
    where go = errFun ps . unsafePackV3
          ps = V.toList $ addAs (-1) $ patch


-- | TODO maybe fix this
-- findClosestPatchSpikeD :: Patches Double -> V3 Double -> (S.Vector Double, LA.Matrix Double)
-- findClosestPatchSpikeD patches v = minimizeVD VectorBFGS2 1e-6 1000 1 0.1 goE goD (unpackV3 v)
--     where goE = errFun ps . unsafePackV3
--           goD = unpackV3 . realDerivates ps . unsafePackV3
--           ps = V.toList $ addAs (-1) $ mergeSpikes patches





oneIteration :: Patches Double -> Phis Double -> Phis Double
oneIteration patches phis = V.zipWith (V.zipWith (+)) phis pushVs

    where pushVs = collapsePushVectors
                 . withStrategy (parTraversable rdeepseq)
                 . V.map (\patch -> oneIterationPatch patch phis) 
                 $ patches

pushVector :: (Epsilon a, Floating a) => (V3 a -> V3 a) -> Phi a -> a -> V.Vector (V3 a)
pushVector dPatch phi fittedA = V.map (\e -> fittedA *^ normalize (dPatch e)) phi

pushVectors :: (Epsilon a, Floating a) => (V3 a -> V3 a) -> Phis a -> As a -> V.Vector (V.Vector (V3 a))
pushVectors dPatch = V.zipWith (pushVector dPatch)

collapsePushVectors :: Fractional a => V.Vector (V.Vector (V.Vector (V3 a))) -> V.Vector (V.Vector (V3 a))
collapsePushVectors vs = V.foldl1' (V.zipWith (V.zipWith (\a b -> a + (b/n)))) vs
    where n = fromIntegral $ length vs

oneIterationPatch :: Patch Double -> Phis Double -> V.Vector (V.Vector (V3 Double))
oneIterationPatch patch phis = pushVectors dPatch phis (V.convert fittedAs)
    where -- find best as
          fittedAs = gradientDescentToFindAs (V.convert patch) phis (V.replicate (V.length phis) 1)
          -- prepare gradient field
          dPatch = realDerivates (V.toList . V.map (\(V3 x y z) -> V4 (-1) x y z) $ patch)


gauss :: V4 Double -> Double
gauss (V4 a b c d) = a * exp( -0.5 * (b**2+c**2+d**2) )
errFun :: [V4 Double] -> V3 Double -> Double
errFun gs (V3 x y z) = sum [ gauss (V4 a (x-b) (y-c) (z-d)) | (V4 a b c d) <- gs ]
squaredErrFun :: [V4 Double] -> V3 Double -> Double
squaredErrFun gs v = (errFun gs v)**2

-- | numeric integration, mostly for comparison
intFun :: [V4 Double] -> (Double,Double)
intFun gs = integrateQAGI 1e-9 1000 (\z -> fst $ integrateQAGI 1e-9 1000 (\y -> fst $ integrateQAGI 1e-9 1000 (\x -> squaredErrFun gs (V3 x y z)) ))

{-realIntegral :: [V4 Double] -> Double-}
{-realIntegral vs = (2*pi)**(3/2) * sum [ a**2 | (V4 a _ _ _) <- vs ]-}
{-                +  2*pi**(3/2)  * sum [ sum [ ai * aj * g (bi-bj) (ci-cj) (di-dj) | (V4 aj bj cj dj) <- is] | ((V4 ai bi ci di):is) <- tails vs ]-}
{-    where g a b c = exp ( -0.25 * (a**2+b**2+c**2))-}

realIntegral' vs (V3 lx ly lz) (V3 hx hy hz) = indefIntegral hx hy hz  - indefIntegral hx hy lz  - indefIntegral hx ly hz  + indefIntegral hx ly lz  
                                             - indefIntegral lx hy hz  + indefIntegral lx hy lz  + indefIntegral lx ly hz  - indefIntegral lx ly lz 
    where indefIntegral x y z = realIntegral vs (V3 x y z)

-- | the integral as calculated by hand (and SAGE)
realIntegralOld vs (V3 x y z) = foo + bar
    where foo = 1/8*pi**(3/2) * sum [ a**2 * erf(x - b) * erf(y - c) * erf(z - d) | (V4 a b c d) <- vs ]
          bar = 1/4*pi**(3/2) * sum [ sum [ aj*ai * erf(x - (bj+bi)/2) * erf(y - (cj+ci)/2) * erf(z - (dj+di)/2) * exp( - 1/4*(bi-bj)**2 - 1/4*(ci-cj)**2  - 1/4*(di-dj)**2) | (V4 aj bj cj dj) <- is ] | ((V4 ai bi ci di):is) <- tails vs ]

-- | the integral "optimized"
realIntegral vs (V3 x y z) = foo
    where foo = 1/8*pi**(3/2) * sum [ fooInner vi + 2 * sum [ barInner vi vj | vj <- js ] | (vi:js) <- tails vs ]
          fooInner (V4 a b c d) = a**2 * erf(x - b) * erf(y - c) * erf(z - d)
          barInner (V4 ai bi ci di) (V4 aj bj cj dj)
            = aj*ai * erf(x - (bj+bi)/2) * erf(y - (cj+ci)/2) * erf(z - (dj+di)/2)
            * exp( - 1/4 * ((bi-bj)**2 + (ci-cj)**2 + (di-dj)) )



-- derivates of the error function

realDerivateX vs (V3 x y z) = -2 * foo * bar
  where foo = sum [ a * (x - b) * gauss (V4 a (x-b) (y-c) (z-d))  | (V4 a b c d) <- vs ]
        bar = sum [ gauss (V4 a (x-b) (y-c) (z-d)) | (V4 a b c d) <- vs ]
  
realDerivateY vs (V3 x y z) = -2 * foo * bar
  where foo = sum [ a * (y - c) * gauss (V4 a (x-b) (y-c) (z-d))  | (V4 a b c d) <- vs ]
        bar = sum [ gauss (V4 a (x-b) (y-c) (z-d)) | (V4 a b c d) <- vs ]

realDerivateZ vs (V3 x y z) = -2 * foo * bar
  where foo = sum [ a * (z - d) * gauss (V4 a (x-b) (y-c) (z-d))  | (V4 a b c d) <- vs ]
        bar = sum [ gauss (V4 a (x-b) (y-c) (z-d)) | (V4 a b c d) <- vs ]

realDerivates vs v = V3 (realDerivateX vs v) (realDerivateY vs v) (realDerivateZ vs v)


test = do


    patches <- V.replicateM 1 (V.replicateM 32 $ (V3 <$> getRandomR (0,128) <*> getRandomR (0,128) <*> pure 0.5)) :: IO (Patches Double)
    phis  <- V.replicateM 2 $ V.replicateM 16 
                            $ (V3 <$> getRandomR (0,128) <*> getRandomR (0,128) <*> getRandomR (0,1)) :: IO (Phis Double)

    let phis' = iterate (oneIteration (patches)) phis
    

    {-let fittedAs = gradientDescentToFindAs patch phis randomAs-}

    
    {-t <- formatTime defaultTimeLocale "%F_%T" <$> getCurrentTime-}
    {-let dn = "data/integration_based_" ++ t ++ "/" -}
    {-createDirectoryIfMissing True dn-}
    

    {-forM_ (zip [0..] phis') $ \ (i,phi) -> do-}
    {-  putStrLn $ "running iteration " ++ show i-}
    {-  encodeFile (dn ++ "it_" ++ show i ++ ".bin") (V.toList . V.map V.toList $ phi)-}

      

    return (patches,phis,phis')




-------------- U T I L I T Y ------------------

mergeSpikes :: (G.Vector v0 (v1 a), G.Vector v1 a) => v0 (v1 a) -> v1 a
mergeSpikes = G.foldl' (G.++) G.empty


-- | add a coefficient to a spike
addA a (V3 x y z) = V4 a x y z
-- | add the same coefficient to a range of spikes
addAs a vs = addA a <$> vs
-- | 'addAs' specialized for Storable Vectors
addAsS a vs = S.map (addA a) vs

-- | create 'V3' from 'Vector'
-- no checks are performed to guarantee that 'v' is of the correct size
unsafePackV3 v = V3 (v G.! 0) (v G.! 1) (v G.! 2)

unpackV3 v = G.fromListN 3 $ toList v


infixl 4 <$$>
(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
f <$$> x = fmap (fmap f) x

infixl 4 <$$$>
(<$$$>) :: (Functor f, Functor g, Functor h) => (a -> b) -> f (g (h a)) -> f (g (h b))
f <$$$> x = fmap (fmap (fmap f)) x
