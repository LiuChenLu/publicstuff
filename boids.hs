import KDTree2d
import Vec2
import System.Random
import System.IO.Unsafe
import Debug.Trace
import Graphics.Gloss
import Graphics.Gloss.Data.Display
import Graphics.Gloss.Data.Picture
import Graphics.Gloss.Interface.IO.Simulate
-- for random seed
--import Data.Time (formatTime, getCurrentTime)
--import System.Locale (defaultTimeLocale)
--import Control.Applicative

data Boid = Boid { identifier :: Int,
                   position :: Vec2,
                   velocity :: Vec2,
                   cohesionScale :: Double,
                   separationScale :: Double,
                   alignmentScale :: Double,
                   dbgC :: Vec2,
                   dbgS :: Vec2,
                   dbgA :: Vec2 } deriving (Eq, Show)

data World = World { width :: Double,
                     height :: Double,
                     pixWidth :: Int,
                     pixHeight :: Int } deriving (Eq, Show)

data Params = Params { aParam :: Double,
                       sScale :: Double,
                       cParam :: Double
                     }

{--

==========================================================================
GRAPHICS 
==========================================================================

--}

modelToScreen :: World -> (Double, Double) -> (Float, Float)
modelToScreen world (x,y) =
  let xscale = (fromIntegral (pixWidth world)) / (width world)
      yscale = (fromIntegral (pixHeight world)) / (height world)
  in
    (realToFrac $ x * xscale, realToFrac $ y * yscale)

scaleFactor :: World -> Float
scaleFactor world =
  let xscale = (fromIntegral (pixWidth world)) / (width world)
      yscale = (fromIntegral (pixHeight world)) / (height world)
  in
   realToFrac $ max xscale yscale

velocityScale :: Float
velocityScale = 10.0 * (realToFrac (max (maxx-minx) (maxy-miny)) :: Float)

--
-- colors
--
boidColor       = makeColor 1.0 1.0 0.0 1.0
-- radiusColor     = makeColor 0.5 1.0 1.0 0.2
cohesionColor :: Boid -> Color
cohesionColor b = makeColor scaled 0.0 0.0 1.0
    where scaled = realToFrac $ (cohesionScale b) / maxcohesion
separationColor :: Boid -> Color
separationColor b = makeColor 0.0 scaled 0.0 1.0
    where scaled = realToFrac $ (separationScale b) / maxseparation
alignmentColor :: Boid -> Color
alignmentColor b = makeColor 0.0 0.0 scaled 1.0
    where scaled = realToFrac $ (alignmentScale b) / maxalignment

renderboid :: World -> Boid -> Picture
renderboid world b =
  let (Vec2 x y) = position b
      sf = 5.0 * (scaleFactor world)
      sf' = 1.0/3.0 * (scaleFactor world)
      sf''= 2.0/3.0 * (scaleFactor world)
      sf'''=1 * (scaleFactor world)
      (xs,ys) = modelToScreen world (x,y)
  in
    Pictures $ [
      Color boidColor $
        Translate xs ys $
        Circle 2 ,
      Color ( cohesionColor b ) $
        Translate xs ys $
        Circle ((realToFrac epsilon) * sf'),
      Color (separationColor b) $
        Translate xs ys $
        Circle ((realToFrac epsilon) * sf''),
      Color ( alignmentColor b ) $
        Translate xs ys $
        Circle ((realToFrac epsilon) * sf''')
    ]

renderboids :: World -> KDTreeNode Boid -> Picture
renderboids world bs =  (Pictures $ mapKDTree bs (renderboid world))

{--

==========================================================================
INITIALIZATION
==========================================================================

--}

rnlist :: Int -> IO [Double]
rnlist n = do
  mapM (\_ -> randomRIO (0,1)) [1..n]

-- sp is scale position
-- sv is scale velocity
initialize :: Int -> Double -> Double -> IO [Boid]
initialize n sp sv = do
  nums <- rnlist (n*7)
  let makeboids [] [] = []
      makeboids (a:b:c:d:e:f:g:rest) (id:ids) =
         (Boid {identifier = id,
                velocity = Vec2 (sv*(0.5 - a)/2.0) (sv*(0.5 - b)/2.0),
                position = Vec2 (sp*(0.5 - c)/2.0) (sp*(0.5 - d)/2.0),
                cohesionScale = maxcohesion * e,
                separationScale = maxseparation * f,
                alignmentScale = maxalignment * g,
                dbgC = vecZero,
                dbgS = vecZero,
                dbgA = vecZero}) : makeboids rest ids
  return $ makeboids nums [1..n]

{--

==========================================================================
VECTOR HELPERS
==========================================================================

--}

-- sometimes we want to control runaway of vector scales, so this can
-- be used to enforce an upper bound
limiter :: Vec2 -> Double -> Vec2
limiter x lim = let d = vecNorm x
                in if (d < lim)
                    then x
                    else vecScale (vecNormalize x) lim

--
-- vector with all components length epsilon
--
epsvec :: Vec2
epsvec = Vec2 epsilon epsilon


{--

==========================================================================
PARAMETERS
==========================================================================

--}
maxcohesion :: Double
maxcohesion = 0.0175 -- originally 0.0075

sParam = 1.25 -- originally 1.25
maxseparation = 0.2 -- orignally 0.1

maxalignment = 1.5 -- orignally 1.0 / 1.8
vLimit = 0.0025 * (max (maxx-minx) (maxy-miny))
epsilon = 0.40
maxx = 8.0
maxy = 8.0
minx = -8.0
miny = -8.0


{--

==========================================================================
BOIDS LOGIC
==========================================================================

--}

-- three rules : cohesion (seek centroid), separation (avoid neighbors),
-- and alignment (fly same way as neighbors)

--
-- centroid is average position of boids, or the vector sum of all
-- boid positions scaled by 1/(number of boids)
--
findCentroid :: [Boid] -> Vec2
findCentroid []    = error "Bad centroid"
findCentroid boids =
  let n = length boids
  in vecScale (foldl1 vecAdd (map position boids)) (1.0 / (fromIntegral n))

--
-- cohesion : go towards centroid.  parameter dictates fraction of
-- distance from boid to centroid that contributes to velocity
--
cohesion :: Boid -> [Boid] -> Double -> Vec2
cohesion b boids a = vecScale diff a
  where c = findCentroid boids
        p = position b
        diff = vecSub c p

-- separation.
separation :: Boid -> [Boid] -> Double -> Vec2
separation b []    a = vecZero
separation b boids a =
  let diff_positions = map (\i -> vecSub (position i) (position b)) boids
      closeby = filter (\i -> (vecNorm i) < a) diff_positions
      sep = foldl vecSub vecZero closeby
  in
    vecScale sep sParam

-- alignment
alignment :: Boid -> [Boid] -> Double -> Vec2
alignment b [] a = vecZero
alignment b boids a =
  let v = foldl1 vecAdd (map velocity boids)
      s = 1.0 / (fromIntegral $ length boids)
      v' = vecScale v s
  in
   vecScale (vecSub v' (velocity b)) a

-- one boid
oneboid :: Boid -> [Boid] -> Boid
oneboid b boids =
  let c = cohesion b boids (cohesionScale b)
      s = separation b boids (separationScale b)
      a = alignment b boids (alignmentScale b)
      p = position b
      v = velocity b
      id = identifier b
      v' = vecAdd (vecAdd v (vecScale (vecAdd c (vecAdd s a)) 0.1))
                  (edge_repel p)
      v'' = limiter (vecScale v' 1.0025) vLimit
      p' = vecAdd p v''
  in
   b { position = wraparound p',
       velocity = v'',
       dbgC = c,
       dbgS = s,
       dbgA = a}


-- Fear edges
-- Pos -> Delta Velocity
edge_repel :: Vec2 -> Vec2
edge_repel (Vec2 x y) = Vec2 (repel x maxx minx) (repel y maxy miny)

      -- Pos    -> Bound  -> Bound  -> Accel
repel :: Double -> Double -> Double -> Double
repel x maxx minx | (x - minx) < cap =   c / (x - minx)**2
                  | (maxx - x) < cap =  -c / (maxx - x)**2
                  | otherwise = 0
    where c = 0.001
          cap = 2

--
-- Neighbor finding code
--
-- This is slightly tricky if we want to represent a world that wraps
-- around in one or more dimensions (aka, a torus or cylinder).
--
-- The issue is that we need to split the bounding box that we query the
-- KDTree with when that box extends outside the bounds of the world.
-- Furthermore, when a set of boids are found in the split bounding boxes
-- representing a neighbor after wrapping around, we need to adjust the
-- relative position of those boids with respect to the reference frame
-- of the central boid.  For example, if the central boid is hugging the left
-- boundary, and another boid is right next to it hugging the right
-- boundary, their proper distance is likely very small.  If the one on the
-- right boundary isn't adjusted, then the distance will actually appear to
-- be very large (approx. the width of the world).
--

findNeighbors :: KDTreeNode Boid -> Boid -> [Boid]
findNeighbors w b =
  let p = position b

      -- bounds
      vlo = vecSub p epsvec
      vhi = vecAdd p epsvec

      -- split the boxes
      splith = splitBoxHoriz (vlo, vhi, 0.0, 0.0)
      splitv = concatMap splitBoxVert splith

      -- adjuster for wraparound
      adj1 ax ay (pos, theboid) = (vecAdd pos av,
                                   theboid { position = vecAdd p av })
        where av = Vec2 ax ay
              p = position theboid

      adjuster lo hi ax ay = let neighbors = kdtRangeSearch w lo hi
                             in map (adj1 ax ay) neighbors

      -- do the sequence of range searches
      ns = concatMap (\(lo,hi,ax,ay) -> adjuster lo hi ax ay) splitv

      -- compute the distances from boid b to members
      dists = map (\(np,n) -> (vecNorm (vecSub p np), n)) ns
  in
    b:(map snd (filter (\(d,_) -> d<=epsilon) dists))


splitBoxHoriz :: (Vec2,Vec2,Double,Double) -> [(Vec2,Vec2,Double,Double)]
splitBoxHoriz (lo@(Vec2 lx ly), hi@(Vec2 hx hy), ax, ay) =
  if (hx-lx > w)
  then [(Vec2 minx ly, Vec2 maxx hy, ax, ay)]
  else if (lx < minx)
       then [(Vec2 minx ly, Vec2 hx hy, ax, ay),
             (Vec2 (maxx-(minx-lx)) ly, Vec2 maxx hy, (ax-w), ay)]
       else if (hx > maxx)
            then [(Vec2 lx ly, Vec2 maxx hy, ax, ay),
                  (Vec2 minx ly, Vec2 (minx + (hx-maxx)) hy, ax+w, ay)]
            else [(lo,hi,ax,ay)]
  where w = maxx-minx

splitBoxVert :: (Vec2,Vec2,Double,Double) -> [(Vec2,Vec2,Double,Double)]
splitBoxVert (lo@(Vec2 lx ly), hi@(Vec2 hx hy), ax, ay) =
  if (hy-ly > h)
  then [(Vec2 lx miny, Vec2 hx maxy, ax, ay)]
  else if (ly < miny)
       then [(Vec2 lx miny, Vec2 hx hy, ax, ay),
             (Vec2 lx (maxy-(miny-ly)), Vec2 hx maxy, ax, ay-h)]
       else if (hy > maxy)
            then [(Vec2 lx ly, Vec2 hx maxy, ax, ay),
                  (Vec2 lx miny, Vec2 hx (miny + (hy-maxy)), ax, ay+h)]
            else [(lo,hi,ax,ay)]
  where h = maxy-miny

wraparound :: Vec2 -> Vec2
wraparound (Vec2 x y) =
 let w = maxx-minx
     h = maxy-miny
     x' = if (x>maxx) then x-w else (if x<minx then x+w else x)
     y' = if (y>maxy) then y-h else (if y<miny then y+h else y)
 in Vec2 x' y'

iterationkd vp step w =
  let boids = mapKDTree w (\i -> oneboid i (findNeighbors w i))
  in foldl (\t b -> kdtAddPoint t (position b) b) newKDTree boids


main :: IO ()
main = do
  let w = World { width = (maxx-minx), height = (maxy-miny), pixWidth = 700, pixHeight = 700 }
  bs <- initialize 100 10.0 0.5
  let t = foldl (\t b -> kdtAddPoint t (position b) b) newKDTree bs
  simulate
    (InWindow "Boids" (pixWidth w, pixHeight w) (10,10))
    (greyN 0.1)
    30
    t
    (renderboids w)
    iterationkd