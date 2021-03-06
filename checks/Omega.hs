{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2009  University of Kent

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program.  If not, see <http://www.gnu.org/licenses/>.
-}

module Omega where

import Control.Arrow
import Control.Monad.State
import Data.Array.IArray
import Data.List
import qualified Data.Map as Map
import Data.Maybe

import Utils


type CoeffIndex = Int
type EqualityConstraintEquation = Array CoeffIndex Integer
type EqualityProblem = [EqualityConstraintEquation]

-- Assumed to be >= 0
type InequalityConstraintEquation = Array CoeffIndex Integer
type InequalityProblem = [InequalityConstraintEquation]

-- | As we proceed with eliminating variables from equations (with the possible
-- addition of one new variable), we perform substitutions like:
-- x_k = a_k'.x_k' + sum (i = 0 .. n without k) of a_i . x_i
-- where a_k' can be zero (no new variable is introduced).
--
-- We want to keep a record of these substitutions because then
-- if we end up with no remaining inequalities, we know the exact results
--   assigned to each of our variables
-- 
-- We need to know the substitution for x_k; that is,
-- we can map from x_k to the RHS of its substitution (including the resolved value for x_k').
-- We keep a map from the original variables into the current variables.
-- This does not require fractional coefficients.
newtype VariableMapping
  = VariableMapping (Map.Map CoeffIndex
      (Either
        ([(Integer, InequalityConstraintEquation)]
          ,[(Integer, InequalityConstraintEquation)])
        EqualityConstraintEquation))
  deriving (Eq, Show)

-- | Given a maximum variable, produces a default mapping
defaultMapping :: Int -> VariableMapping
defaultMapping n = VariableMapping $ Map.empty

-- | Adds a new variable to a map.  The first parameter is (k,value of old x_k)
addEqToMapping :: (CoeffIndex,EqualityConstraintEquation) -> VariableMapping -> VariableMapping
addEqToMapping (k, subst) (VariableMapping vm) = VariableMapping $ addOldToNew vm
  where
    -- We want to update all the existing entries to be scaled according to the new substitution.
    -- Additionally, iff there was no previous entry for k, we should add the new substitution.
    --
    -- In terms of maths, we want to replace cur_a_k . x_k with a value in terms of x_k':
    -- cur_a_k . x_k = cur_a_k . (a_k'.x_k' + sum (i = 0 .. n without k) of a_i . x_i)
    --
    -- So we just add the substitution for x_k, scaled by cur_a_k.
    --
    -- As a more readable example, you currently have:
    --
    -- y = sigma + 3tau
    --
    -- You have a new subsitution:
    -- 
    -- tau = -2sigma - 1
    --
    -- Therefore you must update your reference for y by adding 3*tau:
    --
    -- y = sigma + (-6sigma - 3) = -5sigma - 3
    addOldToNew = (Map.insertWith ignoreNewVal k (Right subst))
                    . (Map.map (transformEither (map (second updateSub) *** map (second updateSub)) updateSub))
      where
        ignoreNewVal = flip const
    
    updateSub eq = arrayZipWith (+) (eq // [(k,0)]) $ scaleEq eq_k subst
      where
        eq_k = eq ! k

addIneqToMapping :: (CoeffIndex, [(Integer, InequalityConstraintEquation)]
  , [(Integer, InequalityConstraintEquation)])
  -> VariableMapping -> VariableMapping
addIneqToMapping (k, ineqA, ineqB) (VariableMapping vm)
  = VariableMapping $ Map.insert k (Left (ineqA, ineqB)) vm
  
-- | Returns a mapping from i to either bunches of lower and upper bounds (with
-- the coefficient of i at the time) or constant values of x_i for the solutions of the equation.
getCounterEqs :: VariableMapping
  -> Map.Map CoeffIndex (Either (Integer, [[(CoeffIndex, Integer)]], [[(CoeffIndex, Integer)]]) Integer)
getCounterEqs (VariableMapping origToLast)
  = Map.delete 0 $ Map.mapWithKey (\k -> transformEither (getBounds k) (! 0)) origToLast
  where
    getBounds :: CoeffIndex -> ([(Integer, InequalityConstraintEquation)]
                               ,[(Integer, InequalityConstraintEquation)])
      -> (Integer, [[(CoeffIndex, Integer)]], [[(CoeffIndex, Integer)]])
    getBounds i (lowerBounds, upperBounds) = (thelcm, merge unNormalisedLower, merge unNormalisedUpper)
      where
            merge = map (mergeBounds thelcm)
            thelcm = foldl lcm 1 $ filter (/= 0) $
              map fst $ unNormalisedLower ++ unNormalisedUpper
            
            unNormalisedLower = map (second assocs) lowerBounds
            unNormalisedUpper = map (second assocs) upperBounds

    mergeBounds :: Integer -> (Integer, [(CoeffIndex, Integer)]) -> [(CoeffIndex, Integer)]
    mergeBounds _ (0, _) = []
    mergeBounds endTarget (cur, vals)
      = map (second (* (endTarget `div` cur))) vals

    
scaleEq :: (IArray a e, Ix i, Num e) => e -> a i e -> a i e
scaleEq n = amap (* n)

-- | Solves all the constraints in the Equality Problem (taking them to be == 0),
-- and transforms the InequalityProblems appropriately.  It also records
-- a variable mapping so that we can feed back the final answer to the user
solveConstraints :: VariableMapping -> EqualityProblem -> InequalityProblem -> Maybe (VariableMapping, InequalityProblem)
solveConstraints vm p ineq
  = normaliseEq p >>= (\p' -> execStateT (solve p') (vm,ineq))
  where
    -- | Normalises an equation by dividing all coefficients by their greatest common divisor.
    -- If the unit coefficient (a_0) doesn't divide by this GCD, Nothing will be returned
    -- (the constraints do not have an integer solution)
    normaliseEq :: EqualityProblem -> Maybe EqualityProblem
    normaliseEq = mapM normaliseEq' --Note the mapM; if any calls to normalise' fail, so will normalise
      where
        normaliseEq' :: EqualityConstraintEquation -> Maybe EqualityConstraintEquation
        normaliseEq' e | g == 0                  = Just e
                       | ((e ! 0) `mod` g) /= 0  = Nothing
                       | otherwise               = Just $ amap (\x -> x `div` g) e
                       where g = mygcdList (tail $ elems e) -- g is the GCD of a_1 .. a_n (not a_0)
    
    -- | Solves all equality problems in the given list.
    -- Will either succeed (Just () in the Error\/Maybe monad) or fail (Nothing)
    solve :: EqualityProblem -> StateT (VariableMapping, InequalityProblem) Maybe ()
    solve [] = return ()
    solve p = (solveUnits p >>* removeRedundant) >>= liftF checkFalsifiable >>= solveNext >>= solve
  
    -- | Checks if any of the coefficients in the equation have an absolute value of 1.
    -- Returns either Just <the first such coefficient> or Nothing (there are no such coefficients in the equation).
    -- This function only looks at a_1 .. a_n.  That is, a_0 is ignored.
    checkForUnit :: EqualityConstraintEquation -> Maybe CoeffIndex
    checkForUnit = listToMaybe . map fst . filter coeffAbsVal1 . tail . assocs
      where
        coeffAbsVal1 :: (a, Integer) -> Bool
        coeffAbsVal1 (_,x) = (abs x) == 1

    -- | Finds the first unit coefficient (|a_k| == 1) in a set of equality constraints.
    -- Returns Nothing if there are no unit coefficients.  Otherwise it returns
    -- (Just (equation, indexOfUnitCoeff), otherEquations); that is, the specified equation is not
    -- present in the list of equations.
    findFirstUnit :: EqualityProblem -> (Maybe (EqualityConstraintEquation,CoeffIndex),EqualityProblem)
    findFirstUnit [] = (Nothing,[])
    findFirstUnit (e:es) = case checkForUnit e of
                             Just ci -> (Just (e,ci),es)
                             Nothing -> let (me,es') = findFirstUnit es in (me,e:es')
                             

    -- | Substitutes a value for x_k into an equation.  Given k, the value for x_k in terms
    -- of coefficients of other variables (let's call it x_k_val), it subsitutes this into
    -- all the equations in the list by adding x_k_val (scaled by a_k) to each equation and
    -- then zeroing out the a_k value.  Note that the (x_k_val ! k) value will be ignored;
    -- it should be zero, in any case (otherwise x_k would be defined in terms of itself!).
    substIn :: CoeffIndex -> Array CoeffIndex Integer -> (VariableMapping, EqualityProblem) -> (VariableMapping, EqualityProblem)
    substIn k x_k_val = transformPair (addEqToMapping (k,x_k_val)) (map substIn')
      where
        substIn' eq = (arrayZipWith (+) eq scaled_x_k_val) // [(k,0)]
          where
            scaled_x_k_val = amap (* (eq ! k)) x_k_val

    -- | Solves (i.e. removes by substitution) all unit coefficients in the given list of equations.
    solveUnits :: EqualityProblem -> StateT (VariableMapping, InequalityProblem) Maybe EqualityProblem
    solveUnits p
      = case findFirstUnit p of
          (Nothing,p') -> return p' -- p' should equal p anyway
          (Just (eq,ind),p') -> modify change >> change' p' >>= liftF normaliseEq >>= solveUnits
            where
              change = substIn ind (arrayMapWithIndex (modifyOthersZeroSpecific ind) eq)
              change' p = do (mp,ineq) <- get
                             let (_,p') = change (undefined,p)
                             put (mp,ineq)
                             return p'
              origVal = eq ! ind

              -- Zeroes a specific coefficient, modifies the others as follows:
              -- If the coefficient of x_k is 1, we need to negate the other coefficients
              -- to get its definition.  However, if the coefficient is -1, we don't need to
              -- do this.  For example, consider 2 + 3x_1 + x_2 - 4x_3 = 0.  In this case
              -- x_2 = -2 - 3x_1 + 4x_3; the negation of the original equation (ignoring x_2).
              -- If however, it was 2 + 3x_1 - x_2 - 4x_3 = 0 then x_2 = 2 + 3x_1 - 4x_3;
              -- that is, identical to the original equation if we ignore x_2.
              modifyOthersZeroSpecific :: CoeffIndex -> (CoeffIndex -> Integer -> Integer)
              modifyOthersZeroSpecific match ind
                | match == ind  = const 0 -- The specific value to zero out
                | origVal == 1  = negate  -- Original coeff was 1; negate
                | otherwise     = id      -- Original coeff was -1; don't do anything
    
    -- | Finds the coefficient with the smallest absolute value of a_1 .. a_n (i.e. not a_0)
    -- that is non-zero (i.e. zero coefficients are ignored).
    findSmallestAbsCoeff :: EqualityConstraintEquation -> CoeffIndex
    findSmallestAbsCoeff = fst . minimumBy cmpAbsSnd . filter ((/= 0) . snd) . tail . assocs
      where
        cmpAbsSnd :: (a,Integer) -> (a,Integer) -> Ordering
        cmpAbsSnd (_,x) (_,y) = compare (abs x) (abs y)

    -- | Solves the next equality and returns the new set of equalities.
    solveNext :: EqualityProblem -> StateT (VariableMapping, InequalityProblem) Maybe EqualityProblem
    solveNext [] = return []
    solveNext (e:es) = -- We transform the kth variable into sigma, effectively
                       -- So once we have x_k = ... (in terms of sigma) we add a_k * RHS
                       -- to all other equations, AFTER zeroing the a_k coefficient (so
                       -- that the multiple of sigma is added on properly)
                       modify change >> change' (e:es) >>= liftF normaliseEq
                         where
                           change' p = do (mp,ineq) <- get
                                          let (_,p') = change (undefined,p)
                                          put (mp,ineq)
                                          return p'
                           change = transformPair (addEqToMapping (k,x_k_eq)) (map alterEquation)
                         
                           -- | Adds a scaled version of x_k_eq onto the current equation, after zeroing out
                           -- the a_k coefficient in the current equation.
                           alterEquation :: EqualityConstraintEquation -> EqualityConstraintEquation
                           alterEquation eq = arrayZipWith (+) (eq // [(k,0)]) (amap (\x -> x * (eq ! k)) x_k_eq)

                           k = findSmallestAbsCoeff e
                           a_k = e ! k
                           m = (abs a_k) + 1
                           sign_a_k = signum a_k
                           x_k_eq = amap (\a_i -> sign_a_k * (a_i `mymod` m)) e // [(k,(- sign_a_k) * m)]

                           -- I think this is probably equivalent to mod, but let's follow the maths:
                           mymod :: Integer -> Integer -> Integer
                           mymod x y = x - (y * (floordivplushalf x y))

                           -- This is floor (x/y + 1/2).  Probably a way to do it without reverting to float arithmetic:
                           floordivplushalf :: Integer -> Integer -> Integer
                           floordivplushalf x y = floor ((fromInteger x / fromInteger y) + (0.5 :: Double))

    -- Removes all equations where the coefficients are all zero
    removeRedundant :: EqualityProblem -> EqualityProblem
    removeRedundant = mapMaybe (boolToMaybe (not . isRedundant))
      where
        isRedundant :: EqualityConstraintEquation -> Bool
        isRedundant = all (== 0) . elems
    

    -- Searches for all equations where only the a_0 coefficient is non-zero; this means the equation cannot be satisfied
    checkFalsifiable :: EqualityProblem -> Maybe EqualityProblem
    checkFalsifiable = boolToMaybe (not . any checkFalsifiable')
      where
        -- | Returns True if the equation is definitely unsatisfiable
        checkFalsifiable' :: EqualityConstraintEquation -> Bool
        checkFalsifiable' e = (e ! 0 /= 0) && (all (== 0) . tail . elems) e


mygcd :: Integer -> Integer -> Integer
mygcd 0 0 = 0
mygcd x y = gcd x y

mygcdList :: [Integer] -> Integer
mygcdList [] = 0
mygcdList [x] = abs x
mygcdList (x:xs) = foldl mygcd x xs

-- | Prunes the inequalities.  It does what is described in section 2.3 of Pugh's ACM paper;
-- it removes redundant inequalities, fails (evaluates to Nothing) if it finds a contradiction
-- and turns any 2x + y <= 4, 2x + y >= 4 pairs into equalities.  The list of such equalities
-- (which may well be an empty list) and the remaining inequalities is returned.
-- As an additional step not specified in the paper, equations with no variables in them are checked
-- for consistency.  That is, all equations c >= 0 (where c is constant) are checked to 
-- ensure c is indeed >= 0, and those equations are removed.  Also, all equations are normalised
-- according to the procedure outlined in the slides.
pruneIneq :: InequalityProblem -> Maybe (EqualityProblem, InequalityProblem)
pruneIneq ineq = do let (opps,others) = splitEither $ groupOpposites $ map pruneGroup groupedIneq
                    (opps', eq) <- mapM checkOpposite opps >>* splitEither
                    checked <- mapM checkConstantEq (concat opps' ++ others) >>* catMaybes
                    return (eq, checked)
  where
    groupedIneq = groupBy (\x y -> EQ == coeffSort x y) $ sortBy coeffSort $ map normaliseIneq ineq

    normaliseIneq :: InequalityConstraintEquation -> InequalityConstraintEquation
    normaliseIneq ineq | g > 1     = arrayMapWithIndex norm ineq
                       | otherwise = ineq
      where
        norm ind val | ind == 0  = normaliseUnits val
                     | otherwise = val `div` g
      
        g = mygcdList $ tail $ elems ineq
        -- I think div would do here, because g will always be positive, but
        -- I feel safer using the mathematical description:
        normaliseUnits a_0 = floor $ (fromInteger a_0 :: Double) / (fromInteger g)

    coeffSort :: InequalityConstraintEquation -> InequalityConstraintEquation -> Ordering
    coeffSort x y = compare (tail $ elems x) (tail $ elems y)

    -- | Takes in a group of inequalities with identical a_1 .. a_n coefficients
    -- and returns the equation with the smallest unit coefficient.  Consider the standard equation:
    -- a_1.x_1 + a_2.x_2 .. a_n.x_n >= -a_0.  We want one equation with the maximum value of -a_0
    -- (this will be the strongest equation), which is therefore the minimum value of a_0.
    -- This therefore automatically removes duplicate and redundant equations.
    pruneGroup :: [InequalityConstraintEquation] -> InequalityConstraintEquation
    pruneGroup = minimumBy (\x y -> compare (x ! 0) (y ! 0))

    -- | Groups all equations with their opposites, if found.  Returns either a pair
    -- or a singleton.  O(N^2), but there shouldn't be that many inequalities to process (<= 10, I expect).
    -- Assumes equations have already been pruned, and that therefore for every unique a_1 .. a_n 
    -- set, there is only one equation.
    groupOpposites :: InequalityProblem -> [Either (InequalityConstraintEquation,InequalityConstraintEquation) InequalityConstraintEquation]
    groupOpposites [] = []
    groupOpposites (e:es) = case findOpposite e es of
                              Just (opp,rest) -> (Left (e,opp)) : (groupOpposites rest)
                              Nothing -> (Right e) : (groupOpposites es)

    findOpposite :: InequalityConstraintEquation -> [InequalityConstraintEquation] -> Maybe (InequalityConstraintEquation,[InequalityConstraintEquation])
    findOpposite _ [] = Nothing
    findOpposite target (e:es) | negTarget == (tail $ elems e) = Just (e,es)
                               | otherwise = case findOpposite target es of
                                               Just (opp,rest) -> Just (opp,e:rest)
                                               Nothing -> Nothing
      where
        negTarget = map negate $ tail $ elems target

    -- Checks if two "opposite" constraints are inconsistent.  If they are inconsistent, Nothing is returned.
    -- If they could be consistent, either the resulting equality or the inequalities are returned
    --
    -- If the equations are opposite, then setting z = sum (1 .. n) of a_n . x_n, the two equations must be:
    -- b + z >= 0
    -- c - z >= 0
    -- The choice of which equation is which is arbitrary.
    --
    -- It is easily seen that adding the two equations gives:
    --
    -- (b + c) >= 0
    -- 
    -- Therefore if (b + c) < 0, the equations are inconsistent.
    -- If (b + c) = 0, we can substitute into the original equations b = -c:
    --   -c + z >= 0
    --   c - z >= 0
    --   Rearranging both gives:
    --   z >= c
    --   z <= c
    --   This implies c = z.  Therefore we can take either of the original inequalities
    --   and treat them directly as equality (c - z = 0, and b + z = 0)
    -- If (b + c) > 0 then the equations are consistent but we cannot do anything new with them
    checkOpposite :: (InequalityConstraintEquation,InequalityConstraintEquation) ->
      Maybe (Either [InequalityConstraintEquation] EqualityConstraintEquation)
    checkOpposite (x,y) | (x ! 0) + (y ! 0) < 0   = Nothing
                        | (x ! 0) + (y ! 0) == 0  = Just $ Right x
                        | otherwise               = Just $ Left [x,y]

    -- The type of this function is quite confusing.  We want to use in the Maybe monad, so 
    -- the outer type indicates error; Nothing is an error.  Just x indicates non-failure,
    -- but x may either be Just y (keep the equation) or Nothing (remove it).  So the three
    -- possible returns are:
    -- * Nothing: Equation inconsistent
    -- * Just Nothing: Equation redundant
    -- * Just (Just e) : Keep equation.
    checkConstantEq :: InequalityConstraintEquation -> Maybe (Maybe InequalityConstraintEquation)
    checkConstantEq eq | all (== 0) (tail $ elems eq) = if (eq ! 0) >= 0 then Just Nothing else Nothing
                       | otherwise = Just $ Just eq

-- | Returns the number of variables (of x_1 .. x_n; x_0 is not counted)
-- that have non-zero coefficients in the given inequality problems.
numVariables :: InequalityProblem -> Int
numVariables ineq = length (nub $ concatMap findVars ineq)
  where
    findVars :: InequalityConstraintEquation -> [CoeffIndex]
    findVars = map fst . filter ((/= 0) . snd) . tail . assocs

-- | Adds a constant value to an equation:
addConstant :: Integer -> Array Int Integer -> Array Int Integer
addConstant x e = e // [(0,(e ! 0) + x)]

-- | Eliminating the inequalities works as follows:
--
-- Rearrange (and normalise) equations for a particular variable x_k to eliminate so that 
-- a_k is always positive and you have:
--  A: a_Ak . x_k <= sum (i is 0 to n, without k) a_Ai . x_i
--  B: a_Bk . x_k >= sum (i is 0 to n, without k) a_Bi . x_i
--  C: equations where a_k is zero.
--
-- Determine if there is an integer solution for x_k:
--
-- If it is an inexact projection, the function recurses into both the real and dark shadow.
-- If necessary, it does brute-forcing.
--
--
-- Real shadow:
--
-- Form lots of new equations:
--  Given  a_Ak . x_k <= RHS(A)
--         a_Bk . x_k >= RHS(B)
--  We can get (since a_Ak and a_bk are positive):
--         a_Ak . A_Bk . x_k <= A_Bk . RHS(A)
--         a_Ak . A_Bk . x_k >= A_Ak . RHS(B)
--  For every combination of the RHS(A) and RHS(B) generate an inequality: a_Bk . RHS(A) - a_Ak . RHS(B) >=0
-- Add these new equations to the set C, and iterate
--
-- Dark shadow:
--
-- Form lots of new equations:
-- Given a_Ak . x_k <= RHS(A)
--       a_Bk . x_k >= RHS(B)
-- We need to form the equations:
--       a_Bk . RHS(A) - a_Ak . RHS(B) - (a_Ak - 1)(a_Bk - 1) >= 0
--
-- That is, the dark shadow is the same as the real shadow but with the constant subtracted

fmElimination :: VariableMapping -> InequalityProblem -> Maybe VariableMapping
fmElimination vm ineq = fmElimination' vm (presentItems ineq) ineq
  where
    -- Finds all variables that have at least one non-zero coefficient in the equation set.
    -- a_0 is ignored; 0 will never be in the returned list
    presentItems :: InequalityProblem -> [Int]
    presentItems = nub . map fst . filter ((/= 0) . snd) . concatMap (tail . assocs)

    -- The real body of the function:
    fmElimination' :: VariableMapping -> [Int] -> InequalityProblem -> Maybe VariableMapping
    fmElimination' vm [] ineqs = pruneAndHandleIneq (vm,ineqs) >>* fst
                                 -- We have to prune the ineqs when they have no variables to
                                 -- ensure none are inconsistent    
    fmElimination' vm indexes@(ix:ixs) ineqs
      = do (vm',ineqsPruned) <- pruneAndHandleIneq (vm,ineqs)
           case listToMaybe $ filter (flip isExactProjection ineqsPruned) indexes of
             -- If there is an exact projection (real shadow = dark shadow), eliminate that
             -- variable, and therefore just recurse to process this shadow:
             Just ex -> let (shad, vm'') = getRealShadow ex (ineqsPruned, vm')
                        in fmElimination' vm'' (indexes \\ [ex]) shad
             Nothing ->
               -- Otherwise, check the real shadow first:
               case let (shad, vm'') = getRealShadow ix (ineqsPruned, vm')
                    in fmElimination' vm'' ixs shad of
                 -- No solution to the real shadow means no solution to the problem:
                 Nothing -> Nothing
                 -- Check the dark shadow:
                 Just vm'' -> case fmElimination' vm'' ixs (getDarkShadow ix ineqsPruned) of
                   -- Solution to the dark shadow means there is a solution to the problem:
                   Just vm''' -> return vm'''
                   -- Solution to real but not to dark; we must brute force the problem.
                   -- If we find any solutions during the brute-forcing, we have our solution.
                   -- Otherwise there is no solution
                   Nothing -> listToMaybe $ mapMaybe (uncurry $ solveProblem' vm'') $ getBruteForceProblems ix ineqsPruned
    
    -- Prunes the inequalities.  If any equalities arise, those are processed, so
    -- that the return is only inequalities
    pruneAndHandleIneq :: (VariableMapping, InequalityProblem) -> Maybe (VariableMapping, InequalityProblem)
    pruneAndHandleIneq (vm,ineq)
      = do (eq,ineq') <- pruneIneq ineq
           if null eq then return (vm,ineq') else solveConstraints vm eq ineq'
    
    
    -- We need to partition the related equations into sets A,B and C.
    -- C is straightforward (a_k is zero).
    -- In set B, a_k > 0, and "RHS(B)" (as described above) is the negation of the other
    -- coefficients.  Therefore "-RHS(B)" is the other coefficients as-is.
    -- In set A, a_k < 0,  and "RHS(A)" (as described above) is the other coefficients, untouched
    -- So we simply zero out a_k, and return the rest, associated with the absolute value of a_k.
    splitBounds :: Int -> InequalityProblem -> ([(Integer, InequalityConstraintEquation)], [(Integer,InequalityConstraintEquation)], [InequalityConstraintEquation])
    splitBounds k = (\(x,y,z) -> (concat x, concat y, concat z)) . unzip3 . map partition'
          where
            partition' e | a_k == 0 = ([],[],[e])
                         | a_k <  0 = ([(abs a_k, e // [(k,0)])],[],[])
                         | a_k >  0 = ([],[(abs a_k, e // [(k,0)])],[])
              where
                a_k = e ! k

    -- Gets the real shadow of a given variable.  The real shadow, for all possible
    -- upper bounds (ax <= alpha) and lower bounds (beta <= bx) is the inequality
    -- (a beta <= b alpha), or (a beta - b alpha >= 0).
    getRealShadow :: Int -> (InequalityProblem, VariableMapping)
      -> (InequalityProblem, VariableMapping)
    getRealShadow k (ineqs, vm)
      = (eqC ++ map (uncurry pairIneqs) (product2 (eqA,eqB))
        ,addIneqToMapping (k, map (second (amap negate)) eqB, eqA) vm)
      where
        (eqA,eqB,eqC) = splitBounds k ineqs
                
        pairIneqs :: (Integer, InequalityConstraintEquation) -> (Integer, InequalityConstraintEquation) -> InequalityConstraintEquation
        pairIneqs (x,ex) (y,ey) = arrayZipWith (+) (amap (* y) ex) (amap (* x) ey)

    -- Gets the dark shadow of a given variable.  The dark shadow, for possible
    -- upper bounds (ax <= alpha) and lower bounds (beta <= bx) is the inequality
    -- (a beta - b alpha - (a - 1)(b - 1) )
    getDarkShadow :: Int -> InequalityProblem -> InequalityProblem
    getDarkShadow k ineqs = eqC ++ map (uncurry pairIneqsDark) (product2 (eqA,eqB))
      where
        (eqA,eqB,eqC) = splitBounds k ineqs
        
        pairIneqsDark :: (Integer, InequalityConstraintEquation) -> (Integer, InequalityConstraintEquation) -> InequalityConstraintEquation
        pairIneqsDark (x,ex) (y,ey) = addConstant (-1*(y-1)*(x-1)) (arrayZipWith (+) (amap (* y) ex) (amap (* x) ey))

    -- Checks if eliminating the specified variable would yield an exact projection (real shadow = dark shadow):
    -- This will be the case if the coefficient on all lower bounds or on all upper bounds is 1.  We check
    -- this by making sure either all the positive coefficients (lower bounds) are 1 or all the negative
    -- coefficients (upper bounds) are -1.
    isExactProjection :: Int -> InequalityProblem -> Bool
    isExactProjection n ineqs = (all (== 1) $ pos n ineqs) || (all (== (-1)) $ neg n ineqs)
      where
        pos :: Int -> InequalityProblem -> [Integer]
        pos n ineqs = filter (> 0) $ map (! n) ineqs
        neg :: Int -> InequalityProblem -> [Integer]
        neg n ineqs = filter (< 0) $ map (! n) ineqs
    
    -- Gets the brute force equality/inequality sets as described in the paper and the slides.
    getBruteForceProblems :: Int -> InequalityProblem -> [(EqualityProblem,InequalityProblem)]
    getBruteForceProblems k ineqs = concatMap setLowerBound eqB
      where
        (eqA,eqB,_) = splitBounds k ineqs
        
        largestUpperA = maximum $ map fst eqA
        
        setLowerBound (b,beta) = map (\i -> ([addConstant (-i) (beta // [(k,b)])],ineqs)) [0 .. max]
          where
            max = ((largestUpperA * b) - largestUpperA - b) `div` largestUpperA

-- | Like solveProblem but allows a custom variable mapping to be used.    
solveProblem' :: VariableMapping -> EqualityProblem -> InequalityProblem -> Maybe VariableMapping
solveProblem' vm eq ineq = solveConstraints vm eq ineq >>= uncurry fmElimination

-- | Solves a problem using the full Omega Test, and a default variable mapping
solveProblem :: EqualityProblem -> InequalityProblem -> Maybe VariableMapping
solveProblem eq ineq = solveProblem' (defaultMapping maxVar) eq ineq
  where
    maxVar = if null eq && null ineq then 0 else
                if null eq then snd $ bounds $ head ineq else snd $ bounds $ head eq
