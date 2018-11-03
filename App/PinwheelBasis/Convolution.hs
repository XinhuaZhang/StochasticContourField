module App.PinwheelBasis.Convolution where

import           App.PinwheelBasis.Pinwheel
import           Control.Monad               as M
import           Control.Parallel.Strategies
import           Data.Array.Repa             as R
import           Data.Complex
import           Data.List                   as L
import           Data.Vector.Storable        as VS
import           Data.Vector.Unboxed         as VU
import           Src.Array.TwoHalfDArray
import           Src.Utils.Coordinates
import           Src.Utils.DFT
import           System.Random

{-# INLINE rotateRepa #-}
rotateRepa :: (Source r e) => R.Array r DIM3 e -> R.Array D DIM3 e
rotateRepa arr =
  let (Z :. a :. b :. c) = extent arr
   in R.backpermute
        (Z :. c :. a :. b)
        (\(Z :. i :. j :. k) -> (Z :. j :. k :. i))
        arr

{-# INLINE projectFilter #-}
projectFilter ::
     R.Array U DIM2 (Complex Double)
  -> HarmonicArray
  -> R.Array U DIM1 (Complex Double)
projectFilter filter (HarmonicArray harmonics) =
  sumS . sumS . rotateRepa $
  traverse2
    harmonics
    filter
    const
    (\f3d f2d idx@(Z :. i :. j :. k) -> f2d (Z :. i :. j) * f3d idx)
    
{-# INLINE projectFilterP #-}
projectFilterP ::
     R.Array U DIM2 (Complex Double)
  -> HarmonicArray
  -> IO (R.Array U DIM1 (Complex Double))
projectFilterP filter (HarmonicArray harmonics) =
  sumP . sumS . rotateRepa $
  traverse2
    harmonics
    filter
    const
    (\f3d f2d idx@(Z :. i :. j :. k) -> f2d (Z :. i :. j) * f3d idx)

{-# INLINE recoverFilter #-}
recoverFilter ::
     R.Array U DIM1 (Complex Double)
  -> HarmonicArray
  -> R.Array U DIM2 (Complex Double)
recoverFilter freqs (ConjugateHarmonicArray harmonics) =
  R.sumS $
  traverse2
    harmonics
    freqs
    const
    (\f3d f1d idx@(Z :. i :. j :. k) -> (conjugate $ f3d idx) * f1d (Z :. k))
    
{-# INLINE recoverFilterP #-}
recoverFilterP ::
     R.Array U DIM1 (Complex Double)
  -> HarmonicArray
  -> IO (R.Array U DIM2 (Complex Double))
recoverFilterP freqs (ConjugateHarmonicArray harmonics) =
  R.sumP $
  traverse2
    harmonics
    freqs
    const
    (\f3d f1d idx@(Z :. i :. j :. k) -> (conjugate $ f3d idx) * f1d (Z :. k))
    

{-# INLINE recoverFilter' #-}
recoverFilter' ::
     R.Array U DIM1 (Complex Double)
  -> HarmonicArray
  -> R.Array U DIM2 (Complex Double)
recoverFilter' freqs (ConjugateHarmonicArray harmonics) =
  R.sumS $
  traverse2
    harmonics
    freqs
    const
    (\f3d f1d idx@(Z :. i :. j :. k) -> (f3d idx) * f1d (Z :. k))

{-# INLINE recoverFilterP' #-}
recoverFilterP' ::
     R.Array U DIM1 (Complex Double)
  -> HarmonicArray
  -> IO (R.Array U DIM2 (Complex Double))
recoverFilterP' freqs (ConjugateHarmonicArray harmonics) =
  R.sumP $
  traverse2
    harmonics
    freqs
    const
    (\f3d f1d idx@(Z :. i :. j :. k) -> (f3d idx) * f1d (Z :. k))

{-# INLINE makeFilter #-}
makeFilter :: (R.Source s e) => R.Array s DIM3 e -> R.Array D DIM3 e
makeFilter arr =
  let (Z :. rows :. cols :. _) = extent arr
   in R.backpermute
        (extent arr)
        (\(Z :. i :. j :. k) ->
           let halfRows = div rows 2
               halfCols = div cols 2
               x =
                 if i < halfRows
                   then i + halfRows
                   else i - halfRows
               y =
                 if j < halfCols
                   then j + halfCols
                   else j - halfCols
            in (Z :. x :. y :. k))
        arr

{-# INLINE projectImage #-}
projectImage ::
     DFTPlan
  -> R.Array U DIM2 (Complex Double)
  -> HarmonicArray
  -> IO (R.Array U DIM3 (Complex Double))
projectImage plan img (HarmonicArray harmonics) = do
  let (Z :. rows :. cols :. freqs) = extent harmonics
      planID2D = DFTPlanID DFT1DG ([rows, cols]) [0, 1]
      planID = DFTPlanID DFT1DG ([rows, cols, freqs]) [0, 1]
      inversePlanID = DFTPlanID IDFT1DG ([rows, cols, freqs]) [0, 1]
      imgVec = VU.convert . toUnboxed $ img
      harmonicsVec = VU.convert . toUnboxed . computeS . makeFilter $ harmonics
  imgVecF <- dftExecute plan planID2D imgVec
  harmonicsVecF <- dftExecute plan planID harmonicsVec
  convolvedVecF <-
    computeP .
    R.traverse2
      (fromUnboxed (extent harmonics) . VS.convert $ harmonicsVecF)
      (fromUnboxed (extent img) . VS.convert $ imgVecF)
      const $
    (\f3d f2d idx@(Z :. i :. j :. k) -> f2d (Z :. i :. j) * f3d idx)
  convolvedVec <-
    dftExecute plan inversePlanID . VU.convert . toUnboxed $ convolvedVecF
  return . fromUnboxed (extent harmonics) . VS.convert $ convolvedVec

{-# INCLUDE recover #-}
recover ::
     DFTPlan
  -> R.Array U DIM3 (Complex Double)
  -> HarmonicArray
  -> IO (R.Array U DIM2 (Complex Double))
recover plan input (ConjugateHarmonicArray harmonics) = do
  let (Z :. rows :. cols :. freqs) = extent harmonics
      planID = DFTPlanID DFT1DG ([rows, cols, freqs]) [0, 1]
      inversePlanID = DFTPlanID IDFT1DG ([rows, cols, freqs]) [0, 1]
      inputVec = VU.convert . toUnboxed $ input
      harmonicsVec = VU.convert . toUnboxed . computeS . makeFilter $ harmonics
  inputVecF <- dftExecute plan planID inputVec
  harmonicsVecF <- dftExecute plan planID harmonicsVec
  convolvedVec <-
    dftExecute plan inversePlanID $
    VS.zipWith (\a b ->  a * conjugate b) inputVecF harmonicsVecF
  return . sumS . fromUnboxed (extent input) . VS.convert $ convolvedVec

{-# INLINE convolve #-}
convolve ::
     DFTPlan
  -> R.Array U DIM2 (Complex Double)
  -> R.Array U DIM2 (Complex Double)
  -> HarmonicArray
  -> HarmonicArray
  -> IO (R.Array U DIM2 (Complex Double))
convolve plan filter input harmonics conjugateHarmonics = do
  filterF <- projectFilterP filter harmonics
  imgF <- projectImage plan input harmonics
  convolvedF <-
    computeP $
    traverse2
      imgF
      filterF
      const
      (\f3d f1d idx@(Z :. i :. j :. k) -> (conjugate $ f1d (Z :. k)) * ( f3d idx))
  convolved <- recover plan convolvedF conjugateHarmonics
  return convolved

{-# INLINE generateDFTPlan #-}
generateDFTPlan :: DFTPlan -> R.Array U DIM3 (Complex Double) -> IO DFTPlan
generateDFTPlan plan arr = do
  let (Z :. rows :. cols :. orientations) = extent arr
  lock <- getFFTWLock
  vecTemp1 <-
    VS.fromList <$> M.replicateM (orientations * rows * cols) randomIO :: IO (VS.Vector Double)
  vecTemp2 <-
    VS.fromList <$> M.replicateM (orientations * rows * cols) randomIO :: IO (VS.Vector Double)
  (plan1, vecTemp3) <-
    dft1dGPlan
      lock
      plan
      ([rows, cols, orientations])
      [0, 1]
      (VS.zipWith mkPolar vecTemp1 vecTemp2)
  (plan2, _) <-
    idft1dGPlan lock plan1 ([rows, cols, orientations]) [0, 1] vecTemp3
  vecTemp4 <-
    VS.fromList <$> M.replicateM (rows * cols) randomIO :: IO (VS.Vector Double)
  vecTemp5 <-
    VS.fromList <$> M.replicateM (rows * cols) randomIO :: IO (VS.Vector Double)
  (plan3, _) <-
    dft1dGPlan
      lock
      plan2
      [rows, cols]
      [0, 1]
      (VS.zipWith mkPolar vecTemp4 vecTemp5)
  return plan3
  
{-# INLINE projectOntoBasis #-}
projectOntoBasis ::
     R.Array U DIM2 (Complex Double)
  -> HarmonicArray
  -> HarmonicArray
  -> R.Array U DIM3 (Complex Double)
projectOntoBasis input (HarmonicArray harmonics) (ConjugateHarmonicArray conjugateHarmonics) =
  computeS $
  traverse2
    harmonics 
    (sumS . sumS . rotateRepa $
     traverse2
       conjugateHarmonics
       input
       const
       (\f3d f2d idx@(Z :. i :. j :. k) -> f2d (Z :. i :. j) * f3d idx))
    const
    (\f3d f1d idx@(Z :. i :. j :. k) -> f3d idx * f1d (Z :. k))

{-# INLINE convolveGabor #-}
convolveGabor ::
     DFTPlan
  -> R.Array U DIM2 (Complex Double)
  -> R.Array U DIM3 (Complex Double)
  -> IO (R.Array U DIM3 (Complex Double))
convolveGabor plan img basis = do
  let (Z :. rows :. cols :. freqs) = extent basis
      planID2D = DFTPlanID DFT1DG ([rows, cols]) [0, 1]
      planID = DFTPlanID DFT1DG ([rows, cols, freqs]) [0, 1]
      inversePlanID = DFTPlanID IDFT1DG ([rows, cols, freqs]) [0, 1]
      imgVec = VU.convert . toUnboxed $ img
      harmonicsVec = VU.convert . toUnboxed . computeS . makeFilter $ basis
  imgVecF <- dftExecute plan planID2D imgVec
  harmonicsVecF <- dftExecute plan planID harmonicsVec
  convolvedVecF <-
    computeP .
    R.traverse2
      (fromUnboxed (extent basis) . VS.convert $ harmonicsVecF)
      (fromUnboxed (extent img) . VS.convert $ imgVecF)
      const $
    (\f3d f2d idx@(Z :. i :. j :. k) -> f2d (Z :. i :. j) * f3d idx)
  convolvedVec <-
    dftExecute plan inversePlanID . VU.convert . toUnboxed $ convolvedVecF
  return . fromUnboxed (extent basis) . VS.convert $ convolvedVec 

{-# INLINE convolve' #-}
convolve' ::
     DFTPlan
  -> R.Array U DIM2 (Complex Double)
  -> R.Array U DIM3 (Complex Double)
  -> HarmonicArray
  -> HarmonicArray
  -> IO (R.Array U DIM2 (Complex Double))
convolve' plan filter imgF harmonics conjugateHarmonics = do
  filterF <- projectFilterP filter harmonics
  convolvedF <-
    computeP $
    traverse2
      imgF
      filterF
      const
      (\f3d f1d idx@(Z :. i :. j :. k) -> (conjugate $ f1d (Z :. k)) * (f3d idx))
  convolved <- recover plan convolvedF conjugateHarmonics
  return convolved
  

-- {-# INLINE convolve'' #-}
-- convolve'' ::
--      DFTPlan
--   -> R.Array U DIM2 (Complex Double)
--   -> R.Array U DIM3 (Complex Double)
--   -> HarmonicArray
--   -> HarmonicArray
--   -> IO (R.Array U DIM2 (Complex Double))
-- convolve'' plan filter imgF harmonics conjugateHarmonics = do
--   filterF <- projectFilterP filter harmonics
 
--   convolved <- recover plan convolvedF conjugateHarmonics
--   return convolved

