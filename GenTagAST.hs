{-
Tock: a compiler for parallel languages
Copyright (C) 2007  University of Kent

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

-- | Generates the TagAST module.  Template Haskell was a bit too heavyweight
-- for this.  Uses Data.Generics to pick out all the constructors for the
-- given types, work out their "arity" and write out the TagAST module
-- (to stdout).
module GenTagAST where

import Data.Generics
import Data.List (intersperse)

import qualified AST as A

genHeader :: [String]
genHeader = [
  "-- | Contains lots of helper functions for matching AST elements."
 ,"-- For most AST.Blah items, there is an mBlah and mBlah' definition here."
 ,"-- mBlah is without the Meta tag pattern (DontCare is used), mBlah' is with a Meta tag pattern."
 ,"--"
 ,"-- NOTE: This file is auto-generated by the GenTagAST program, and should not be edited directly."
 ,"module TagAST where"
 ,"import Data.Generics"
 ,""
 ,"import qualified AST"
 ,"import qualified Metadata"
 ,"import Pattern"
 ,"import TreeUtils"
 -- Could probably auto-generate these, too:
 ,"type F0 = Pattern"
 ,"type F1 = (Data a0) => a0 -> Pattern"
 ,"type F2 = (Data a0, Data a1) => a0 -> a1 -> Pattern"
 ,"type F3 = (Data a0, Data a1, Data a2) => a0 -> a1 -> a2 -> Pattern"
 ,"type F4 = (Data a0, Data a1, Data a2, Data a3) => a0 -> a1 -> a2 -> a3 -> Pattern"
 ,"type F5 = (Data a0, Data a1, Data a2, Data a3, Data a4) => a0 -> a1 -> a2 -> a3 -> a4 -> Pattern"
 ,"type F6 = (Data a0, Data a1, Data a2, Data a3, Data a4, Data a5) => a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> Pattern"
 ,"type F0' a = Pattern"
 ,"type F1' a0 = a0 -> Pattern"
 ,"type F2' a1 = (Data a0) => a0 -> a1 -> Pattern"
 ,"type F3' a2 = (Data a0, Data a1) => a0 -> a1 -> a2 -> Pattern"
 ,"type F4' a3 = (Data a0, Data a1, Data a2) => a0 -> a1 -> a2 -> a3 -> Pattern"
 ,"type F5' a4 = (Data a0, Data a1, Data a2, Data a3) => a0 -> a1 -> a2 -> a3 -> a4 -> Pattern"
 ,"type F6' a5 = (Data a0, Data a1, Data a2, Data a3, Data a4) => a0 -> a1 -> a2 -> a3 -> a4 -> a5 -> Pattern" 
 ,""
 ]

genItem :: (Int, String) -> [String]
genItem (num, name)
  = [mname ++ "' :: F" ++ n
    ,mname ++ "' = tag" ++ n ++ " AST." ++ name
    ,mname ++ " :: F" ++ show (num - 1)
    ,mname ++ " = " ++ mname ++ "' DontCare"]
  where
    n = show num
    mname = "m" ++ name

genItem' :: String -> String -> (Int, String, [String]) -> [String]
genItem' suffix typeName (num, name, paramTypes)
  = [mname ++ "' :: F" ++ n ++ typeSuffix
    ,mname ++ "' = tag" ++ n ++ " (AST." ++ name ++ " :: " ++ params ++ ")"
    ,mname ++ " :: F" ++ show (num - 1) ++ typeSuffix
    ,mname ++ " = " ++ mname ++ "' DontCare"]
  where
    typeSuffix = ""

    params = concat $ intersperse " -> " $ paramTypes ++ [typeName]

    n = show num
    mname = "m" ++ name ++ suffix

consFor :: forall a. Data a => a -> [(Int, String)]
consFor x = map consFor' (dataTypeConstrs $ dataTypeOf x)
  where
    -- The way I work out how many arguments a constructor takes is crazy, but
    -- I can't see a better way given the Data.Generics API
    consFor' :: Constr -> (Int, String)
    consFor' con = (glength (fromConstr con :: a), showConstr con)

consParamsFor :: forall a. Data a => a -> [(Int, String, [String])]
consParamsFor x = map consParamsFor' (dataTypeConstrs $ dataTypeOf x)
  where
    -- The way I work out how many arguments a constructor takes is crazy, but
    -- I can't see a better way given the Data.Generics API
    consParamsFor' :: Constr -> (Int, String, [String])
    consParamsFor' con = (length cons, showConstr con, cons)
      where
        cons :: [String]
        cons = gmapQ (show . typeOf) (fromConstr con :: a)

items :: [(Int, String)]
items = concat
 [consFor (u :: A.Actual)
 ,consFor (u :: A.Alternative)
 ,consFor (u :: A.ArrayConstr)
 ,consFor (u :: A.ArrayElem)
 ,consFor (u :: A.Choice)
 ,consFor (u :: A.Expression)
 ,consFor (u :: A.ExpressionList)
 ,consFor (u :: A.Formal)
 ,consFor (u :: A.InputItem)
 ,consFor (u :: A.InputMode)
 ,consFor (u :: A.LiteralRepr)
 ,consFor (u :: A.OutputItem)
 ,consFor (u :: A.Option)
 ,consFor (u :: A.Process)
 ,consFor (u :: A.Replicator)
 ,consFor (u :: A.Specification)
 ,consFor (u :: A.SpecType)
 ,consFor (u :: A.Subscript)
 ,consFor (u :: A.Type)
 ,consFor (u :: A.Variable)
 ,consFor (u :: A.Variant)
 ]
 where
   u = undefined

struct :: [String]
struct = concat 
 [consP "P" (undefined :: A.Structured A.Process)
 ,consP "O" (undefined :: A.Structured A.Option)
 ,consP "C" (undefined :: A.Structured A.Choice)
 ,consP "V" (undefined :: A.Structured A.Variant)
 ,consP "A" (undefined :: A.Structured A.Alternative)
 ,consP "EL" (undefined :: A.Structured A.ExpressionList)
 ,consP "AST" (undefined :: A.Structured ())
 ]
  where
    consP prefix w = concatMap (genItem' prefix (show $ typeOf w)) $ consParamsFor w


filterInvalid :: [(Int, a)] -> [(Int, a)]
filterInvalid = filter (\(n,_) -> n > 0)

joinLines :: [String] -> String
joinLines xs = concat [x ++ "\n" | x <- xs]

main :: IO ()
main = putStr $ joinLines $ genHeader ++ concatMap genItem (filterInvalid items) ++ struct
