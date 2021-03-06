{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008, 2010  University of Kent

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

module TreeUtils (
  MatchErrors, 
  AnyDataItem(..), Items, castADI, 
  assertPatternMatch, testPatternMatch, testPatternMatchOneOf, getMatchedItems, 
  tag0, tag1, tag2, tag3, tag4, tag5, tag6, tag7, tag1d, tag2d, tag3d, tag4d, tag5d, tag6d, tag7d, 
  (@@),
  mkPattern, stopCaringPattern, namePattern, nameAndStopCaringPattern, 
  checkTreeForConstr,
  con0, con1, con2, con3, con4, con5, con6, con7
  , decomp1, decomp2, decomp3, decomp4, decomp5
  , mkM', gmapFuncs
  ) where

import Control.Monad.State
import Data.Generics
import Data.List
import qualified Data.Map as Map
import Data.Maybe
import Data.Ord
import Test.HUnit hiding (State)

import Pattern
import qualified PrettyShow as PS
import TestFramework

type MatchErrors = [String]

-- | A data item used when matching items of interest.  Note that it is similar to Pattern but not the same;
--   AnyDataItem can only contain Data, and has no other special values.
--   We do not use Data.Dynamic because Dynamic only requires Typeable a; we want Data a to enable us
--   to test the items for equality.
data AnyDataItem = forall a. Data a => ADI a

instance Show AnyDataItem where
  show (ADI a) = gshow a

instance Eq AnyDataItem where
  (==) (ADI x) (ADI y) = case (cast y) of
                           -- Same type, use the library-provided geq function to compare them:
                           Just y' -> geq x y'
                           -- Different types, so not equal
                           Nothing -> False

-- | A type representing the state involved in recording items of interest.  It is simply a map
--   from arbitrary string keys to AnyDataItem, which is just a wrapper for any item of class Data
type Items = Map.Map String AnyDataItem

castADI :: (Typeable b) => Maybe AnyDataItem -> Maybe b
castADI (Just (ADI x)) = cast x
castADI Nothing = Nothing


-- | A function that takes a string key (of an item of interest), and a value.
--   If the key has NOT been seen before, checkItem merely records its value in the set of items of interest
--   If the key has been seen before, checkItem checks that the new (passed) value matches the old value.
checkItem :: String -> AnyDataItem -> State Items MatchErrors
checkItem key val 
  = do items <- get
       case Map.lookup key items of
         Just foundVal -> return $
             if foundVal == val then []
             --show key will put quote marks around it, and escape any special characters (which seems useful here):
             else ["Item of interest does not match prior value for key " ++ (show key) ++ ", prior: " ++ (show foundVal) ++ " current: " ++ (show val)]
         Nothing -> do {put (Map.insert key val items) ; return [] }

-- | The implementation of Eq for Constr is not complete -- it only checks whether the constructors have the same index.  Given:
--
--data XYZ = X | Y | Z
-- deriving (Data)
--data ABC = A | B
-- deriving (Data) 
--
-- (toConstr B) == (toConstr Y)
--
-- So we do our best, comparing the names too
conElem :: Constr -> [Constr] -> Bool
conElem _ [] = False
conElem c (x:xs) = ((c == x) && (show c == show x)) || conElem c xs

-- | A function that takes an expected Pattern value, an actual Data value, and returns the appropriate checks
--   for pseudo-equality.  This pseudo-equality is equality, enhanced by the possibility of Pattern's 
--   DontCare and Named (item-of-interest) values which match differently.
checkMatch :: Data z => Pattern -> z -> State Items MatchErrors
-- | DontCare matches anything, so return an empty assertion:
checkMatch DontCare _ = return []
-- | Items of interest are delegated to the checkItem function that uses the Items state
checkMatch (Named s p) b = sequenceS [checkMatch p b, checkItem s (ADI b)]
-- | Constructors are matched using the applyAll function (but we must also check the constructors are equal)
checkMatch m@(Match con items) b 
    -- Check the patterns are consistent; see note #1 below this checkMatch function
  = case ((not $ isAlgType (dataTypeOf b)) || (conElem con (dataTypeConstrs $ dataTypeOf b))) of
    False -> return ["Inconsistent pattern (your program has been written wrongly), constructor not possible here: " 
        ++ (show con) ++ " possible constructors are: " ++ (show (dataTypeConstrs $ dataTypeOf b))
        ++ " in pattern:\n" ++ (PS.pshow m) ++ "\n*** trying to match against actual value:\n" ++ (PS.pshow b)]
    True ->  
      case (checkConsEq con (toConstr b) m b) of
         Nothing -> sequenceS $ (applyAll items b)
         Just err -> return [err] --no point comparing fields if the constructors don't match
  where 
    --The whole things are given as third/fourth parameters just so we can produce a more helpful error message:
    checkConsEq :: Data z => Constr -> Constr -> Pattern -> z -> Maybe String
    checkConsEq a b a' b' = if (a == b) 
                  then Nothing
                  else Just $ "Constructors not equal, expected constructor: " ++ (show a) ++ " actual cons: " ++ (show b)
                               ++ " while trying to match expected:\n" ++ (PS.pshow a') ++ "\n*** against actual:\n " ++ (PS.pshow b')
 
    -- | applyAll checks that the non-constructor items of an algebraic data type are matched:
    applyAll :: Data z => [Pattern] -> z -> [State Items MatchErrors]
    applyAll list d = map (applyAll' d) (zip [0..] list)
    applyAll' :: Data z => z -> (Int,Pattern) -> State Items MatchErrors
    applyAll' d (index,f) 
      = if (index >= numIndexes) 
        then return ["Invalid index in applyAll: " ++ (show index) ++ ", numIndexes is: " ++ (show numIndexes) 
               ++ " trying to check, expected: " ++ (PS.pshow f) ++ " actual: " ++ (PS.pshow d)]
        else (gmapQi index (checkMatch f) d) 
      --Possibly a better way?
      where
        numIndexes = glength d


{-
Note #1 (referenced above):

There was a problem with using the tag functions for building patterns:

Given a data structure:

data Vegetable = Carrot | Potato | Broccoli
data Meat = Beef | Pork

data Meal = MeatTwoVeg Meat (Vegetable,Vegetable)

there was nothing to stop you doing any of this:

tag2 MeatTwoVeg Carrot (Potato, Broccoli)
tag2 MeatTwoVeg Carrot (Beef, Potato)
tag2 MeatTwoVeg Beef [Carrot, Pork]

And so on and so forth.  Of course, an inconsistent pattern for Meal such as those above can never match Meal; it is an error in the program.

I could have prevented this by wrapping the tag functions in an error monad, or by doing checks inside the tag functions that could die using error,
but a better solution seemed to be to gather the error checking into assertPatternMatch/getMatchedItems, since they already have the option
to return errors.  So you can build an inconsistent pattern, but when you come to use it you will get an error highlighting your mistake of
creating an inconsistent pattern (rather than simply a did-not-match error)
-}


-- | A helper function for concating awkward lists in monads
sequenceS :: [State Items MatchErrors] -> State Items MatchErrors
--We have [State Items MatchErrors]
--We want State Items MatchErrors
--sequence :: [State Items MatchErrors] -> State Items [MatchErrors]
--concat :: [MatchErrors] -> MatchErrors
sequenceS x = (liftM concat) (sequence x)    

-- | A function for checking that two Data items (expected, actual) match, where the expected item (LHS)
--   may contain special Pattern values (such as DontCare, Named, etc)
testPatternMatch :: (Data y, Data z, TestMonad m r) => String -> y -> z -> m ()
testPatternMatch msg exp act = 
  --Sometimes it can be hard to understand the MatchErrors as they stand.  When you are told "1 expected, found 0" it's often hard
  --to know exactly which part of your huge match that refers to, especially if you can't see a 1 in your match.  So to add a little
  --bit of help, I append a pretty-printed version of the pattern and data to each error.
  sequence_ $ map (
    testFailure 
    . (append $ " while testing pattern:\n" ++ (PS.pshow exp) ++ "\n*** against actual:\n" ++ (PS.pshow act)) 
    . ((++) $ msg ++ " ")
  ) errors
  where 
    errors = evalState (checkMatch (mkPattern exp) act) (Map.empty)
    append x y = y ++ x

-- | A function for checking that an actual Data item matches one of a list of
-- expected items, where each expected item (LHS) may contain special Pattern values (such as DontCare, Named, etc)
testPatternMatchOneOf :: (Data y, Data z, TestMonad m r) => String -> [y] -> z -> m ()
testPatternMatchOneOf msg exps act = 
  --Sometimes it can be hard to understand the MatchErrors as they stand.  When you are told "1 expected, found 0" it's often hard
  --to know exactly which part of your huge match that refers to, especially if you can't see a 1 in your match.  So to add a little
  --bit of help, I append a pretty-printed version of the pattern and data to each error.
  sequence_
    [testFailure $ msg ++ " " ++ " while testing pattern:\n" ++ (PS.pshow exp)
      ++ "\n*** against actual:\n" ++ (PS.pshow act)
    | err <- errors]
  where 
    (exp, errors) = head $ sortBy (comparing (length . snd))
      [(exp, evalState (checkMatch (mkPattern exp) act) (Map.empty)) | exp <- exps]

assertPatternMatch :: (Data y, Data z) => String -> y -> z -> Assertion
assertPatternMatch = testPatternMatch

-- | A function for getting the matched items from the patterns on the LHS
--   Either returns the matched items, or a list of errors from the matching
getMatchedItems :: (Data y, Data z) => y -> z -> Either MatchErrors Items
getMatchedItems a b 
  = case errors of
      [] -> Right items
      _ -> Left errors
    where (errors,items) = runState (checkMatch (mkPattern a) b) (Map.empty)


--The mkPattern function needs to be able to take things such as:
-- v :: Pattern
-- (w:ws) :: [Pattern]
-- (x0,x1) :: (Pattern,Pattern)
-- (y0,y1,y2) :: Data b => (Pattern,Pattern,b)
--And return an Pattern:
-- v
-- Match (:) [w,mkPattern ws]
-- Match (,) [x0,x1]
-- Match (,,) [y0,y1,mkPattern u]
--The latter three could be rephrased as:
-- Match (:) [mkPattern w,mkPattern ws]
-- Match (,) [mkPattern x0,mkPattern x1]
-- Match (,,) [mkPattern y0,mkPattern y1,mkPattern u]
--Therefore the whole function can be viewed as: get the constructor, and map mkPattern over the sub-elements

mkPattern :: (Data a) => a -> Pattern
mkPattern x = case cast x of
  Just x' -> x'
  Nothing -> Match (toConstr x) (gmapQ mkPattern x)


-- | Replaces (mkPattern a) with DontCare everywhere in the given pattern
stopCaringPattern :: Data a => a -> Pattern -> Pattern
-- We can't use everywhere, because Pattern doesn't have a proper gunfold implementation
stopCaringPattern item = stopCaringPattern' (mkPattern item)
  where
    stopCaringPattern' :: Pattern -> Pattern -> Pattern
    stopCaringPattern' replace p@(DontCare) = p
    stopCaringPattern' replace p@(Named n p') = if (p == replace) then DontCare else (Named n $ stopCaringPattern' replace p')
    stopCaringPattern' replace p@(Match c ps) = if (p == replace) then DontCare else (Match c $ map (stopCaringPattern' replace) ps)
 
-- | Replaces (mkPattern a) with (Named "name" (mkPattern a)) everywhere in the given pattern
-- Useful to combine with stopCaringPattern; if you already know the value, there would be little point in naming it.
-- Use namePattern, then stopCaringPattern; it won't be much help in the other order (nameAndStopCaringPattern does this already).
-- If the pattern you pass to replace is (Named n' p), this will be transformed to (Named n p)
namePattern :: Data a => String -> a -> Pattern -> Pattern
namePattern name item = namePattern' name (mkPattern item)
  where
    namePattern' :: String -> Pattern -> Pattern -> Pattern
    namePattern' n replace p@(DontCare) = if (p == replace) then Named n p else p
    namePattern' n replace p@(Named n' p') = if (p == replace) then Named n (namePattern' n replace p') else Named n' (namePattern' n replace p')
    namePattern' n replace p@(Match c ps) = if (p == replace) then Named n $ Match c $ map (namePattern' n replace) ps else Match c $ map (namePattern' n replace) ps

nameAndStopCaringPattern :: Data a => String -> a -> Pattern -> Pattern
nameAndStopCaringPattern n item = (stopCaringPattern item) . (namePattern n item)


(@@) :: Data a => String -> a -> Pattern
(@@) label x = Named label (mkPattern x)

--I'm not sure tag0 is ever needed, but just in case:
tag0 :: (Data a) => a -> Pattern
tag0 con = (Match (toConstr con) [])


-- | A helper function.  The parameters are: constructor item0 item1, where the constructor has arity 2
tag1 :: (Data a, Data b0) => (a0  -> a) -> b0 -> Pattern
tag1 con x0 = (Match (toConstr con') [mkPattern x0])
  where
    con' = con (undefined :: a0)

-- | A helper function.  The parameters are: constructor item0 item1, where the constructor has arity 2
tag2 :: (Data a, Data b0, Data b1) => (a0 -> a1 -> a) -> b0 -> b1 -> Pattern
tag2 con x0 x1 = (Match (toConstr con') [mkPattern x0,mkPattern x1])
  where
    con' = con (undefined :: a0) (undefined :: a1)

-- | A helper function.  The parameters are: constructor item0 item1 item2, where the constructor has arity 3
tag3 :: (Data a, Data b0, Data b1, Data b2) => (a0 -> a1 -> a2 -> a) -> b0 -> b1 -> b2 -> Pattern
tag3 con x0 x1 x2 = (Match (toConstr con') [mkPattern x0,mkPattern x1,mkPattern x2])
  where
    con' = con (undefined :: a0) (undefined :: a1) (undefined :: a2)

-- | A helper function.  The parameters are: constructor item0 item1 item2 item3, where the constructor has arity 4
tag4 :: (Data a, Data b0, Data b1, Data b2, Data b3) => (a0 -> a1 -> a2 -> a3 -> a) -> b0 -> b1 -> b2 -> b3 -> Pattern
tag4 con x0 x1 x2 x3 = (Match (toConstr con') [mkPattern x0,mkPattern x1,mkPattern x2,mkPattern x3])
  where
    con' = con (undefined :: a0) (undefined :: a1) (undefined :: a2) (undefined :: a3)

-- | A helper function.  The parameters are: constructor item0 item1 item2 item3 item4, where the constructor has arity 5
tag5 :: (Data a, Data b0, Data b1, Data b2, Data b3, Data b4) => 
          (a0 -> a1 -> a2 -> a3 -> a4 -> a) -> b0 -> b1 -> b2 -> b3 -> b4 -> Pattern
tag5 con x0 x1 x2 x3 x4 = (Match (toConstr con') [mkPattern x0,mkPattern x1,mkPattern x2,mkPattern x3,mkPattern x4])
  where
    con' = con (undefined :: a0) (undefined :: a1) (undefined :: a2) (undefined :: a3) (undefined :: a4)
    
-- | A helper function.  The parameters are: constructor item0 item1 item2 item3 item4 item5, where the constructor has arity 6
tag6 :: (Data a, Data b0, Data b1, Data b2, Data b3, Data b4, Data b5) => 
          (a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> a) -> b0 -> b1 -> b2 -> b3 -> b4 -> b5 -> Pattern
tag6 con x0 x1 x2 x3 x4 x5 = (Match (toConstr con') [mkPattern x0,mkPattern x1,mkPattern x2,mkPattern x3,mkPattern x4,mkPattern x5])
  where
    con' = con (undefined :: a0) (undefined :: a1) (undefined :: a2) (undefined :: a3) (undefined :: a4) (undefined :: a5)


-- | A helper function.  The parameters are: constructor item0 item1 item2 item3 item4 item5 item6, where the constructor has arity 7
tag7 :: (Data a, Data b0, Data b1, Data b2, Data b3, Data b4, Data b5, Data b6) => 
          (a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> a) -> b0 -> b1 -> b2 -> b3 -> b4 -> b5 -> b6 -> Pattern
tag7 con x0 x1 x2 x3 x4 x5 x6 = (Match (toConstr con') [mkPattern x0,mkPattern x1,mkPattern x2,mkPattern x3,mkPattern x4,mkPattern x5,mkPattern x6])
  where
    con' = con (undefined :: a0) (undefined :: a1) (undefined :: a2) (undefined :: a3) (undefined :: a4) (undefined :: a5) (undefined :: a6)

-- | Like tag1, but with DontCare for all the sub-items
tag1d :: (Data a) => (a0  -> a) -> Pattern
tag1d x = tag1 x DontCare

-- | Like tag2, but with DontCare for all the sub-items
tag2d :: (Data a) => (a0 -> a1 -> a) -> Pattern
tag2d x = tag2 x DontCare DontCare

-- | Like tag3, but with DontCare for all the sub-items
tag3d :: (Data a) => (a0 -> a1 -> a2 -> a) -> Pattern
tag3d x = tag3 x DontCare DontCare DontCare

-- | Like tag4, but with DontCare for all the sub-items
tag4d :: (Data a) => (a0 -> a1 -> a2 -> a3 -> a) -> Pattern
tag4d x = tag4 x DontCare DontCare DontCare DontCare

-- | Like tag5, but with DontCare for all the sub-items
tag5d :: (Data a) => (a0 -> a1 -> a2 -> a3 -> a4 -> a) -> Pattern
tag5d x = tag5 x DontCare DontCare DontCare DontCare DontCare

-- | Like tag6, but with DontCare for all the sub-items
tag6d :: (Data a) => (a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> a) -> Pattern
tag6d x = tag6 x DontCare DontCare DontCare DontCare DontCare DontCare

-- | Like tag7, but with DontCare for all the sub-items
tag7d :: (Data a) => (a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> a) -> Pattern
tag7d x = tag7 x DontCare DontCare DontCare DontCare DontCare DontCare DontCare


-- | Checks that the given tree does not contain any of the constructors supplied.
-- Returns a list of all tree items matching those constructors
checkTreeForConstr :: Data a => [Constr] -> a -> [AnyDataItem]
checkTreeForConstr cons = makeCheckFunction $ zip (map constrType cons) cons
  where
    makeCheckFunction :: Data a => [(DataType, Constr)] -> (a -> [AnyDataItem])
    makeCheckFunction tcs = listify' (anyFunc $ ((map makeCheckFunction' tcs) :: [GenericQ' Bool]))

    -- anyFunc takes a list of generic queries, and returns a single generic query that ORs the results together
    -- Note that this is not the same as using foldl and extQ, because extQ deals with type-specific cases,
    -- not generic queries as we have here.
    anyFunc :: [GenericQ' Bool] -> GenericQ Bool
    anyFunc [] _ = False
    anyFunc (f:fs) x = (unGQ f x) || (anyFunc fs x)

    -- listify expects a type-specific function as its parameter, not a generic query.
    -- This function only differs from listify by using a generic query, and wrapping the result in an AnyDataItem wrapper.
    listify' :: GenericQ Bool -> GenericQ [AnyDataItem]
    listify' f = everything (++) f'
      where
        f' :: GenericQ [AnyDataItem]
        f' x = if (f x) then [ADI x] else []

    -- checks that the DataType and Constr match the given Data item.
    makeCheckFunction' :: (DataType, Constr) -> (GenericQ' Bool)
    makeCheckFunction' (tr,con) = GQ (\d -> let c = toConstr d
      in (show (dataTypeOf d) == show tr) && (c == con) && (show c == show con))

-- | Converts a 0-argument constructor into its Constr form.
con0 :: Data a => a -> Constr
con0 = toConstr

-- | Converts a 1-argument constructor into its Constr form.
con1 :: Data a => (a0  -> a) -> Constr
con1 f = toConstr (f undefined)

-- | Converts a 2-argument constructor into its Constr form.
con2 :: Data a => (a0 -> a1 -> a) -> Constr
con2 f = toConstr (f undefined undefined)

-- | Converts a 3-argument constructor into its Constr form.
con3 :: Data a => (a0 -> a1 -> a2 -> a) -> Constr
con3 f = toConstr (f undefined undefined undefined)

-- | Converts a 4-argument constructor into its Constr form.
con4 :: Data a => (a0 -> a1 -> a2 -> a3 -> a) -> Constr
con4 f = toConstr (f undefined undefined undefined undefined)

-- | Converts a 5-argument constructor into its Constr form.
con5 :: Data a => (a0 -> a1 -> a2 -> a3 -> a4 -> a) -> Constr
con5 f = toConstr (f undefined undefined undefined undefined undefined)

-- | Converts a 6-argument constructor into its Constr form.
con6 :: Data a => (a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> a) -> Constr
con6 f = toConstr (f undefined undefined undefined undefined undefined undefined)

-- | Converts a 7-argument constructor into its Constr form.
con7 :: Data a => (a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> a) -> Constr
con7 f = toConstr (f undefined undefined undefined undefined undefined undefined undefined)


popFunc :: Monad m => GenericM (StateT [GenericM' m] m)
popFunc x = do (f:fs) <- get
               put fs
               lift ((unGM f) x)

mkM' :: (Monad m, Typeable a) => (a -> m a)-> GenericM' m
mkM' f = GM {unGM = mkM f}

gmapFuncs :: (Monad m, Data a) => [GenericM' m] -> a -> m a
gmapFuncs funcs term = evalStateT (gmapM popFunc term) funcs

decompCheckCons :: Monad m => Constr -> Constr -> m ()
decompCheckCons cx cy = if (cx == cy) && (show cx == show cy) then return () else fail ("Constructors did not match: " ++ show cx ++ " and " ++ show cy)

decomp1 :: (Monad m, Data a, Typeable a0) => (a0 -> a) -> (a0 -> m a0) -> (a -> m a)
decomp1 con f0 x = decompCheckCons (con1 con) (toConstr x) >> gmapFuncs [mkM' f0] x

decomp2 :: (Monad m, Data a, Typeable a0, Typeable a1) => (a0 -> a1 -> a) -> (a0 -> m a0) -> (a1 -> m a1) -> (a -> m a)
decomp2 con f0 f1 x = decompCheckCons (con2 con) (toConstr x) >> gmapFuncs [mkM' f0, mkM' f1] x

decomp3 :: (Monad m, Data a, Typeable a0, Typeable a1, Typeable a2) => (a0 -> a1 -> a2 -> a) -> (a0 -> m a0) -> (a1 -> m a1) -> (a2 -> m a2) -> (a -> m a)
decomp3 con f0 f1 f2 x = decompCheckCons (con3 con) (toConstr x) >> gmapFuncs [mkM' f0, mkM' f1, mkM' f2] x

decomp4 :: (Monad m, Data a, Typeable a0, Typeable a1, Typeable a2, Typeable a3) =>
  (a0 -> a1 -> a2 -> a3 -> a) -> (a0 -> m a0) -> (a1 -> m a1) -> (a2 -> m a2) -> (a3 -> m a3) -> (a -> m a)
decomp4 con f0 f1 f2 f3 x = decompCheckCons (con4 con) (toConstr x) >> gmapFuncs [mkM' f0, mkM' f1, mkM' f2, mkM' f3] x

decomp5 :: (Monad m, Data a, Typeable a0, Typeable a1, Typeable a2, Typeable a3, Typeable a4) =>
  (a0 -> a1 -> a2 -> a3 -> a4 -> a) -> (a0 -> m a0) -> (a1 -> m a1) -> (a2 -> m a2) -> (a3 -> m a3) -> (a4 -> m a4) -> (a -> m a)
decomp5 con f0 f1 f2 f3 f4 x = decompCheckCons (con5 con) (toConstr x) >> gmapFuncs [mkM' f0, mkM' f1, mkM' f2, mkM' f3, mkM' f4] x

