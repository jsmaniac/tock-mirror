{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008, 2009  University of Kent

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

-- | Contains test for various shared passes.
module PassTest (tests) where

import Control.Monad.State hiding (guard)
import Data.Generics (cast, Data, Typeable)
import qualified Data.Map as Map
import Test.HUnit hiding (State)

import qualified AST as A
import CompState
import Metadata
import OccamEDSL
import Pattern
import SimplifyComms
import SimplifyExprs
import TagAST
import TestUtils
import TreeUtils
import Types
import Unnest
import Utils

m :: Meta
m = emptyMeta

-- | An expression list containing a single value of 0.
valof0 :: A.Structured A.ExpressionList
valof0 = A.Only m $ A.ExpressionList m [intLiteral 0]

-- | An expression list containing variables with the two given names.
valofTwo :: String -> String -> A.Structured A.ExpressionList
valofTwo a b = A.Only m $ A.ExpressionList m [exprVariable a,exprVariable b]

-- | Looks up an item from the Items, and attempts to cast it.  Fails (via assertions) if
-- either the item is not found, or if the cast is invalid.
assertGetItemCast  :: Typeable t => String -> Items -> IO t
assertGetItemCast k kv 
  = case (Map.lookup k kv) of
      Nothing -> (assertFailure "Internal error; expected item not present") >> return (undefined)
      Just (ADI v) -> case (cast v) of
        Just v' -> return v'
        Nothing -> (assertFailure $ "Wrong type when casting in assertGetItemCast for key: " ++ k) >> return (undefined)

-- | Given a body, returns a function spec:
singleParamFunc :: A.Structured A.ExpressionList -> A.Specification
singleParamFunc body = A.Specification m (simpleName "foo") (A.Function m (A.PlainSpec,
  A.PlainRec) [A.Int] [A.Formal A.ValAbbrev A.Byte (simpleName "param0")] (Just $ Left body))

singleParamFuncProc :: A.Process -> A.Specification
singleParamFuncProc body = A.Specification m (simpleName "foo") (A.Function m (A.PlainSpec,
  A.PlainRec) [A.Int] [A.Formal A.ValAbbrev A.Byte (simpleName "param0")] (Just $ Right body))

-- | Returns the expected body of the single parameter process (when the function had valof0 as a body)
singleParamBodyExp :: Pattern -- ^ to match: Maybe A.Process
singleParamBodyExp = mkPattern $ Just $ tag2 A.Seq DontCare $ mOnlyP $
                         tag3 A.Assign DontCare [tag2 A.Variable DontCare (Named "ret0" DontCare)] $ tag2 A.ExpressionList DontCare [intLiteral 0]

-- | Returns the expected specification type of the single parameter process
singleParamSpecExp :: Pattern -> Pattern -- ^ to match: A.SpecType
singleParamSpecExp body = tag4 A.Proc DontCare (A.PlainSpec, A.PlainRec) [tag3 A.Formal A.ValAbbrev A.Byte (simpleName "param0"), tag3 A.Formal A.Abbrev A.Int (Named "ret0" DontCare)] body

-- | Tests a function with a single return, and a single parameter.
testFunctionsToProcs0 :: Test
testFunctionsToProcs0 = TestCase $ testPassWithItemsStateCheck "testFunctionsToProcs0" exp functionsToProcs orig (return ()) check
  where
    orig = singleParamFunc valof0
    exp = tag3 A.Specification DontCare (simpleName "foo") procSpec
    procSpec = singleParamSpecExp singleParamBodyExp
                             --check return parameters were defined:
    check (items,state) = do ret0 <- ((assertGetItemCast "ret0" items) :: IO A.Name)                        
                             assertVarDef "testFunctionsToProcs0" state (A.nameName ret0) $
                               tag7 A.NameDef DontCare (A.nameName ret0) (A.nameName ret0)
                                 (A.Declaration m A.Int) A.Abbrev A.NameNonce A.Unplaced
                             --check proc was defined:
                             assertVarDef "testFunctionsToProcs0" state "foo" $
                               tag7 A.NameDef DontCare ("foo") ("foo")
                                 procSpec A.Original A.NameUser A.Unplaced
                             --check csFunctionReturns was changed:
                             assertEqual "testFunctionsToProcs0" (Just [A.Int]) (Map.lookup "foo" (csFunctionReturns state)) 

-- | Tests a function with multiple returns, and multiple parameters.
testFunctionsToProcs1 :: Test
testFunctionsToProcs1 = TestCase $ testPassWithItemsStateCheck "testFunctionsToProcs1 A" exp functionsToProcs orig (return ()) check
  where
    orig = A.Specification m (simpleName "foo") (A.Function m (A.PlainSpec, A.Recursive) [A.Int,A.Real32] 
      [A.Formal A.ValAbbrev A.Byte (simpleName "param0"),A.Formal A.Abbrev A.Real32 (simpleName "param1")] (Just $ Left $ valofTwo "param0" "param1"))
    exp = tag3 A.Specification DontCare (simpleName "foo") procBody
    procBody = tag4 A.Proc DontCare (A.PlainSpec, A.Recursive)
                                                [tag3 A.Formal A.ValAbbrev A.Byte (simpleName "param0"), 
                                                 tag3 A.Formal A.Abbrev A.Real32 (simpleName "param1"),
                                                 tag3 A.Formal A.Abbrev A.Int (Named "ret0" DontCare),
                                                 tag3 A.Formal A.Abbrev A.Real32 (Named "ret1" DontCare)] $
                 Just $ tag2 A.Seq DontCare $
                   mOnlyP $ 
                     tag3 A.Assign DontCare [tag2 A.Variable DontCare (Named "ret0" DontCare),tag2 A.Variable DontCare (Named "ret1" DontCare)] $ 
                       tag2 A.ExpressionList DontCare [exprVariable "param0",exprVariable "param1"]
                             --check return parameters were defined:
    check (items,state) = do ret0 <- ((assertGetItemCast "ret0" items) :: IO A.Name)
                             ret1 <- ((assertGetItemCast "ret1" items) :: IO A.Name)
                             assertVarDef "testFunctionsToProcs1 B" state (A.nameName ret0) $
                               tag7 A.NameDef DontCare (A.nameName ret0) (A.nameName ret0)
                                 (A.Declaration m A.Int) A.Abbrev A.NameNonce A.Unplaced
                             assertVarDef "testFunctionsToProcs1 C" state (A.nameName ret1) $
                               tag7 A.NameDef DontCare (A.nameName ret1) (A.nameName ret1)
                                 (A.Declaration m A.Real32) A.Abbrev A.NameNonce A.Unplaced
                             --check proc was defined:
                             assertVarDef "testFunctionsToProcs1 D" state "foo" $
                               tag7 A.NameDef DontCare ("foo") ("foo")
                                 procBody A.Original A.NameUser A.Unplaced
                             --check csFunctionReturns was changed:
                             assertEqual "testFunctionsToProcs1 E" (Just [A.Int,A.Real32]) (Map.lookup "foo" (csFunctionReturns state)) 

-- | Tests a function that contains a function.
-- Currently I have chosen to put DontCare for the body of the function as stored in the NameDef.
-- This behaviour is not too important, and may change at a later date.
testFunctionsToProcs2 :: Test
testFunctionsToProcs2 = TestCase $ testPassWithItemsStateCheck "testFunctionsToProcs2 A" exp functionsToProcs orig (return ()) check
  where
    orig = A.Specification m (simpleName "fooOuter") (A.Function m (A.PlainSpec,
      A.PlainRec) [A.Int] [A.Formal A.ValAbbrev A.Byte (simpleName "paramOuter0")] $ Just $ Left $
      A.Spec m (singleParamFunc valof0) valof0)
    exp = tag3 A.Specification DontCare (simpleName "fooOuter") procBodyOuter
    procHeader body = tag4 A.Proc DontCare (A.PlainSpec, A.PlainRec) [tag3 A.Formal A.ValAbbrev A.Byte (simpleName "paramOuter0"), tag3 A.Formal A.Abbrev A.Int (Named "retOuter0" DontCare)] body
    procBodyOuter = procHeader $ Just $
                 tag2 A.Seq DontCare $                 
                   mSpecP (tag3 A.Specification DontCare (simpleName "foo") (singleParamSpecExp singleParamBodyExp)) $
                     mOnlyP $ 
                       tag3 A.Assign DontCare [tag2 A.Variable DontCare (Named "retOuter0" DontCare)] $ tag2 A.ExpressionList DontCare [intLiteral 0]


                             --check return parameters were defined:
    check (items,state) = do retOuter0 <- ((assertGetItemCast "retOuter0" items) :: IO A.Name)
                             ret0 <- ((assertGetItemCast "ret0" items) :: IO A.Name)
                             assertVarDef "testFunctionsToProcs2 B" state (A.nameName ret0) $
                               tag7 A.NameDef DontCare (A.nameName ret0) (A.nameName ret0)
                                 (A.Declaration m A.Int) A.Abbrev A.NameNonce A.Unplaced
                             assertVarDef "testFunctionsToProcs2 C" state (A.nameName retOuter0) $
                               tag7 A.NameDef DontCare (A.nameName retOuter0) (A.nameName retOuter0)
                                 (A.Declaration m A.Int) A.Abbrev A.NameNonce A.Unplaced
                             --check proc was defined:
                             assertVarDef "testFunctionsToProcs2 D" state "foo" $
                               tag7 A.NameDef DontCare ("foo") ("foo") (singleParamSpecExp DontCare)
                                 A.Original A.NameUser A.Unplaced
                             assertVarDef "testFunctionsToProcs2 E" state "fooOuter" $
                               tag7 A.NameDef DontCare ("fooOuter") ("fooOuter") (procHeader DontCare)
                                 A.Original A.NameUser A.Unplaced
                             --check csFunctionReturns was changed:
                             assertEqual "testFunctionsToProcs2 F" (Just [A.Int]) (Map.lookup "foo" (csFunctionReturns state)) 
                             assertEqual "testFunctionsToProcs2 G" (Just [A.Int]) (Map.lookup "fooOuter" (csFunctionReturns state)) 

-- | Tests a function with a single return, and a single parameter, with a Process body
testFunctionsToProcs3 :: Test
testFunctionsToProcs3 = TestCase $ testPassWithItemsStateCheck "testFunctionsToProcs3" exp functionsToProcs orig (return ()) check
  where
    orig = singleParamFuncProc $ A.Seq m $ A.Only m $ A.Assign m [variable "foo"] $ A.ExpressionList m [intLiteral 0]
    exp = tag3 A.Specification DontCare (simpleName "foo") procSpec
    procSpec = singleParamSpecExp singleParamBodyExp
                             --check return parameters were defined:
    check (items,state) = do ret0 <- ((assertGetItemCast "ret0" items) :: IO A.Name)                        
                             assertVarDef "testFunctionsToProcs3" state (A.nameName ret0) $
                               tag7 A.NameDef DontCare (A.nameName ret0) (A.nameName ret0)
                                 (A.Declaration m A.Int) A.Abbrev A.NameNonce A.Unplaced
                             --check proc was defined:
                             assertVarDef "testFunctionsToProcs3" state "foo" $
                               tag7 A.NameDef DontCare ("foo") ("foo")
                                 procSpec A.Original A.NameUser A.Unplaced
                             --check csFunctionReturns was changed:
                             assertEqual "testFunctionsToProcs3" (Just [A.Int]) (Map.lookup "foo" (csFunctionReturns state)) 

-- | Tests a function with multiple returns, and multiple parameters.
testFunctionsToProcs4 :: Test
testFunctionsToProcs4 = TestCase $ testPassWithItemsStateCheck "testFunctionsToProcs4 A" exp functionsToProcs orig (return ()) check
  where
    orig = A.Specification m (simpleName "foo") (A.Function m (A.PlainSpec, A.PlainRec) [A.Int,A.Real32] 
      [A.Formal A.ValAbbrev A.Byte (simpleName "param0"),A.Formal A.Abbrev A.Real32 (simpleName "param1")] $
        Just $ Right $ A.Seq m $ A.Only m $ A.Assign m [variable "foo"] $ A.ExpressionList m [exprVariable "param0", exprVariable "param1"])
    exp = tag3 A.Specification DontCare (simpleName "foo") procBody
    procBody = tag4 A.Proc DontCare (A.PlainSpec, A.PlainRec) [tag3 A.Formal A.ValAbbrev A.Byte (simpleName "param0"), 
                                                 tag3 A.Formal A.Abbrev A.Real32 (simpleName "param1"),
                                                 tag3 A.Formal A.Abbrev A.Int (Named "ret0" DontCare),
                                                 tag3 A.Formal A.Abbrev A.Real32 (Named "ret1" DontCare)] $
                 Just $ tag2 A.Seq DontCare $
                   mOnlyP $ 
                     tag3 A.Assign DontCare [tag2 A.Variable DontCare (Named "ret0" DontCare),tag2 A.Variable DontCare (Named "ret1" DontCare)] $ 
                       tag2 A.ExpressionList DontCare [exprVariable "param0",exprVariable "param1"]
                             --check return parameters were defined:
    check (items,state) = do ret0 <- ((assertGetItemCast "ret0" items) :: IO A.Name)
                             ret1 <- ((assertGetItemCast "ret1" items) :: IO A.Name)
                             assertVarDef "testFunctionsToProcs4 B" state (A.nameName ret0) $
                               tag7 A.NameDef DontCare (A.nameName ret0) (A.nameName ret0)
                                 (A.Declaration m A.Int) A.Abbrev A.NameNonce A.Unplaced
                             assertVarDef "testFunctionsToProcs4 C" state (A.nameName ret1) $
                               tag7 A.NameDef DontCare (A.nameName ret1) (A.nameName ret1)
                                 (A.Declaration m A.Real32) A.Abbrev A.NameNonce A.Unplaced
                             --check proc was defined:
                             assertVarDef "testFunctionsToProcs4 D" state "foo" $
                               tag7 A.NameDef DontCare ("foo") ("foo")
                                 procBody A.Original A.NameUser A.Unplaced
                             --check csFunctionReturns was changed:
                             assertEqual "testFunctionsToProcs4 E" (Just [A.Int,A.Real32]) (Map.lookup "foo" (csFunctionReturns state)) 


skipP :: A.Structured A.Process
skipP = A.Only m (A.Skip m)

-- | Tests that a simple constructor (with no expression, nor function call) gets converted into the appropriate initialisation code
testTransformConstr0 :: Test
testTransformConstr0 = TestCase $ testPass "transformConstr0" exp transformConstr orig startState
  where
    startState :: State CompState ()
    startState = defineConst "x" A.Int (intLiteral 42)

    t = A.Array [dimension 10] A.Int

    orig = A.Spec m (A.Specification m (simpleName "arr") $
      A.Is m A.ValAbbrev t $ A.ActualExpression $ A.Literal m t $ A.ArrayListLiteral m $
        A.Spec m (A.Specification m (simpleName "x") (A.Rep m (A.For m (intLiteral 0) (intLiteral 10)
          (intLiteral 1))))
          $ (A.Only m $ exprVariable "x")) skipP
    exp = nameAndStopCaringPattern "indexVar" "i" $ mkPattern exp'
    exp' = A.Spec m (A.Specification m (simpleName "arr") (A.Declaration m t)) $
      A.ProcThen m 
      (A.Seq m $ A.Spec m (A.Specification m (simpleName "i")
          (A.Declaration m A.Int)) $
        A.Several m [A.Only m $ A.Assign m [variable "i"] $
            A.ExpressionList m [intLiteral 0],
          A.Spec m (A.Specification m (simpleName "x") $ A.Rep m (A.For m (intLiteral 0) (intLiteral 10) (intLiteral 1))) $
            A.Several m
              [A.Only m $ A.Assign m
                [A.SubscriptedVariable m (A.Subscript m A.NoCheck $
                  exprVariable "i") (variable "arr")] $
                    A.ExpressionList m [exprVariable "x"],
               A.Only m $ A.Assign m [variable "i"] $ A.ExpressionList m
                 [addExprsInt (intLiteral 1) (exprVariable "i")]]
          ]
      )
      skipP


testOutExprs :: Test
testOutExprs = TestList
 [
  -- Test outputting from an expression:
  TestCase $ testPassWithItemsStateCheck "testOutExprs 0" 
    (tag2 A.Seq DontCare $ (abbr "temp_var" A.Int (eXM A.Int 1))
      (mOnlyP $ tag3 A.Output emptyMeta chan
        [tag2 A.OutExpression emptyMeta (tag2 A.ExprVariable DontCare (tag2 A.Variable DontCare (Named "temp_var" DontCare)))])
    )
    outExprs (
      A.Output emptyMeta chan [outXM A.Int 1]
    )
    (do defineOccamOperators
        defineName (xName) $ simpleDefDecl "x" A.Int)
    (checkTempVarTypes "testOutExprs 0" [("temp_var", A.Int)])

  -- Test outputting from a variable already:
  ,TestCase $ testPass "testOutExprs 1" 
    (tag2 A.Seq DontCare $
      (mOnlyP $ tag3 A.Output emptyMeta chan
        [outX])
    )
    outExprs (
      A.Output emptyMeta chan [outX]
    )
    (return ())
    
  -- Test outputting from multiple output items:
  ,TestCase $ testPassWithItemsStateCheck "testOutExprs 2"
    (tag2 A.Seq DontCare $ (abbr "temp_var0" A.Byte (eXM A.Byte 1)) $ (abbr "temp_var1" A.Int (intLiteral 2))
      (mOnlyP $ tag3 A.Output emptyMeta chan
        [tag2 A.OutExpression emptyMeta (tag2 A.ExprVariable DontCare (tag2 A.Variable DontCare (Named "temp_var0" DontCare)))
        ,mkPattern outX
        ,tag2 A.OutExpression emptyMeta (tag2 A.ExprVariable DontCare (tag2 A.Variable DontCare (Named "temp_var1" DontCare)))
        ]
      )
    )
    outExprs (
      A.Output emptyMeta chan [outXM A.Byte 1,outX,A.OutExpression emptyMeta $ intLiteral 2]
    )
    (do defineOccamOperators
        defineName (xName) $ simpleDefDecl "x" A.Byte)
    (checkTempVarTypes "testOutExprs 2" [("temp_var0", A.Byte),("temp_var1", A.Int)])
    
  -- Test an OutCounted
  ,TestCase $ testPassWithItemsStateCheck "testOutExprs 3"
    (tag2 A.Seq DontCare $ (abbr "temp_var" A.Byte (eXM A.Byte 1))
      (mOnlyP $ tag3 A.Output emptyMeta chan
        [tag3 A.OutCounted emptyMeta 
          (tag2 A.ExprVariable DontCare (tag2 A.Variable DontCare (Named "temp_var0" DontCare)))
          (exprVariable "x")
        ]
      )
    )
    outExprs (
      A.Output emptyMeta chan [A.OutCounted emptyMeta (eXM A.Byte 1) (exprVariable "x")]
    )
    (do defineOccamOperators
        defineName (xName) $ simpleDefDecl "x" A.Byte)
    (checkTempVarTypes "testOutExprs 3" [("temp_var", A.Byte)])

  -- Test that OutputCase is also processed:
  ,TestCase $ testPassWithItemsStateCheck "testOutExprs 4" 
    (tag2 A.Seq DontCare $ (abbr "temp_var" A.Int (eXM A.Int 1))
      (mOnlyP $ tag4 A.OutputCase emptyMeta chan (simpleName "foo")
        [tag2 A.OutExpression emptyMeta (tag2 A.ExprVariable DontCare (tag2 A.Variable DontCare (Named "temp_var" DontCare)))])
    )
    outExprs (
      A.OutputCase emptyMeta chan (simpleName "foo") [outXM A.Int 1]
    )
    (do defineOccamOperators
        defineName (xName) $ simpleDefDecl "x" A.Int)
    (checkTempVarTypes "testOutExprs 4" [("temp_var", A.Int)])

  -- Test that an empty outputcase works okay:

  ,TestCase $ testPass "testOutExprs 5" 
    (tag2 A.Seq DontCare $
      (mOnlyP $ A.OutputCase emptyMeta chan (simpleName "foo") [])
    )
    outExprs (
      A.OutputCase emptyMeta chan (simpleName "foo") []
    )
    (return ())

 ]
 where
   outX = A.OutExpression emptyMeta $ exprVariable "x"
   outXM t n = A.OutExpression emptyMeta $ eXM t n
   eXM t n = buildExpr $ Dy (Var "x") "-" (Lit $ integerLiteral t n)
  
   abbr key t e = mSpecP
     (tag3 A.Specification DontCare (Named key DontCare)
       $ mIs A.ValAbbrev t
         $ mActualExpression' e)
 
   chan = variable "c"
   xName = simpleName "x"
   

testInputCase :: Test
testInputCase = TestList
  [
   -- Input that only involves tags:
   {-
   The idea is to transform:
     c ? CASE
       a0
         --Process p0
   into:
     SEQ
       INT tag:
       SEQ
         c ? tag
         CASE tag
           a0
             --Process p0
   -}
   testOccamPassTransform "testInputCase 0" (nameAndStopCaringPattern "tag" "A") (
     defineProtocolAndC $
       (oC *? oCASEinput
         [inputCaseOption (a0, [], p0)]
       )
       `becomes`
       oSEQ
          [declNonce (return A.Int) oA
            [oC *? oA
            ,oCASE oA
              [caseOption ([0 :: Int], p0)]
            ]
          ]
   ) transformInputCase

   -- Input that involves multiple tags and multiple inputs:
   {-
   The idea is to transform:
     c ? CASE
       a0
         --Process p0
       c1 ; z
         --Process p1
       b2 ; x ; y
         --Process p2
   into:
     SEQ
       INT tag:
       SEQ
         c ? tag
         CASE tag
           a0
             --Process p0
           c1
             SEQ
               c ? z
               --Process p1
           b2
             SEQ
               c ? x ; y
               --Process p2
   -}
   ,testOccamPassTransform "testInputCase 1" (nameAndStopCaringPattern "tag" "A") (
     defineProtocolAndC $
       (oC *? oCASEinput
         [inputCaseOption (a0, [], p0)
         ,inputCaseOption (c1, [oZ], p1)
         ,inputCaseOption (b2, [oX, oY], p2)
         ]
       )
       `becomes`
       oSEQ
          [declNonce (return A.Int) oA
            [oC *? oA
            ,oCASE oA
              [caseOption ([0 :: Int], p0)
              ,caseOption ([2 :: Int], oSEQ
                [oC *? oZ
                ,p1])
              ,caseOption ([1 :: Int], oSEQ
                [oC *? sequence [oX, oY]
                ,p2])
              ]
            ]
          ]
   ) transformInputCase

   -- Input that involves multiple tags and multiple inputs and specs (sheesh!):
   {-
   The idea is to transform:
     c ? CASE
       a0
         --Process p0
       INT z:
       c1 ; z
         --Process p1
       INT x:
       INT y:
       b2 ; x ; y
         --Process p2
   into:
     SEQ
       INT tag:
       SEQ
         c ? tag
         CASE tag
           a0
             --Process p0
           INT z:
           c1
             SEQ
               c ? z
               --Process p1
           INT x:
           INT y:
           b2
             SEQ
               c ? x ; y
               --Process p2
   -}
   ,testOccamPassTransform "testInputCase 2" (nameAndStopCaringPattern "tag" "A") (
     defineProtocolAndC $
       (oC *? oCASEinput
         [inputCaseOption (a0, [], p0)
         ,decl (return A.Int) oZ [inputCaseOption (c1, [oZ], p1)]
         ,decl (return A.Int) oX
           [decl (return A.Int) oY
             [inputCaseOption (b2, [oX, oY], p2)]]
         ]
       )
       `becomes`
       oSEQ
          [declNonce (return A.Int) oA
            [oC *? oA
            ,oCASE oA
              [caseOption ([0 :: Int], p0)
              ,decl (return A.Int) oZ [caseOption ([2 :: Int], oSEQ
                [oC *? oZ
                ,p1])]
              ,decl (return A.Int) oX
                [decl (return A.Int) oY
                  [caseOption ([1 :: Int], oSEQ
                    [oC *? sequence [oX, oY]
                    ,p2])]]
              ]
            ]
          ]
   ) transformInputCase

   -- Input that only involves tags:
   {-
   The idea is to transform:
     ALT
       c ? CASE
         a0
           --Process p0
   into:
     ALT
       INT tag:
       c ? tag
         CASE tag
           a0
             --Process p0
   -}
   ,testOccamPassTransform "testInputCase 100" (nameAndStopCaringPattern "tag" "A") (
     defineProtocolAndC $
       (oALT
         [guard (oC *? oCASEinput
           [inputCaseOption (a0, [], p0)], return $ A.Skip emptyMeta)
         ]
       )
       `becomes`
       oALT
          [declNonce (return A.Int) oA
            [guard (oC *? oA,
              oCASE oA
                [caseOption ([0 :: Int], p0)])
            ]
          ]
   ) transformInputCase
  ]
  where
    a0 = simpleName "a0"
    b2 = simpleName "b2"
    c1 = simpleName "c1"

    defineProtocolAndC :: Occ (A.Structured A.Process) -> Occ (A.Structured A.Process)
    defineProtocolAndC =
      decl' (simpleName "prot")
        (A.ProtocolCase emptyMeta [(a0,[]),(b2,[A.Int,A.Int]),(c1,[A.Int])])
          A.Original A.NameUser
          . singleton . decl (return $ A.Chan (A.ChanAttributes A.Unshared A.Unshared)
                               (A.UserProtocol $ simpleName "prot")) oC . singleton
    
testTransformProtocolInput :: Test
testTransformProtocolInput = TestList
  [
    TestCase $ testPass "testTransformProtocolInput0"
      (seqItems [ii0])
      transformProtocolInput (seqItems [ii0])
      (return ())
   ,TestCase $ testPass "testTransformProtocolInput1"
      (A.Seq emptyMeta $ A.Several emptyMeta $ map onlySingle [ii0, ii1, ii2])
      transformProtocolInput (seqItems [ii0, ii1, ii2])
      (return ())
   
   ,TestCase $ testPass "testTransformProtocolInput2"
      (A.Alt emptyMeta False $ onlySingleAlt ii0)
      transformProtocolInput (A.Alt emptyMeta False $ onlySingleAlt ii0)
      (return ())

   ,TestCase $ testPass "testTransformProtocolInput3"
      (A.Alt emptyMeta True $ A.Only emptyMeta $ A.Alternative emptyMeta (A.True
        emptyMeta) (variable "c") (A.InputSimple emptyMeta [ii0] Nothing) $
        A.Seq emptyMeta $ A.Several emptyMeta $ onlySingle ii1 : [A.Only emptyMeta $ A.Skip emptyMeta])
      transformProtocolInput (A.Alt emptyMeta True $ A.Only emptyMeta $ altItems [ii0, ii1])
      (return ())

   ,TestCase $ testPass "testTransformProtocolInput4"
      (A.Alt emptyMeta False $ A.Only emptyMeta $ A.Alternative emptyMeta (A.True
        emptyMeta) (variable "c") (A.InputSimple emptyMeta [ii0] Nothing) $
        A.Seq emptyMeta $ A.Several emptyMeta $ map onlySingle [ii1,ii2] ++ [A.Only emptyMeta $ A.Skip emptyMeta])
      transformProtocolInput (A.Alt emptyMeta False $ A.Only emptyMeta $ altItems [ii0, ii1, ii2])
      (return ())
  ]
  where
   ii0 = A.InVariable emptyMeta (variable "x")
   ii1 = A.InCounted emptyMeta (variable "y") (variable "z")
   ii2 = A.InVariable emptyMeta (variable "a")
  
   onlySingle = A.Only emptyMeta . A.Input emptyMeta (variable "c") . flip (A.InputSimple emptyMeta) Nothing . singleton
   onlySingleAlt = A.Only emptyMeta . flip (A.Alternative emptyMeta (A.True
     emptyMeta) (variable "c")) (A.Skip emptyMeta) . flip (A.InputSimple emptyMeta) Nothing . singleton
   seqItems = A.Input emptyMeta (variable "c") . flip (A.InputSimple emptyMeta) Nothing
   altItems = flip (A.Alternative emptyMeta (A.True emptyMeta) (variable "c")) (A.Skip emptyMeta)
                 . flip (A.InputSimple emptyMeta) Nothing


testPullRepCounts :: Test
testPullRepCounts = TestList
  [
   testUnchanged 4 $ A.If emptyMeta

   ,forAllThree $ \blockType -> testOccamPassTransform "testPullRepCounts 5" (nameAndStopCaringPattern "nonce" "A")
      (blockType
        [decl' (simpleName "X")
          (A.Rep emptyMeta (A.For emptyMeta (intLiteral 0) (intLiteral 6) (intLiteral 1)))
            A.Original A.NameUser []
        ]
      `becomes`
       blockType
        [decl' (simpleName "A")
          (A.Is emptyMeta A.ValAbbrev A.Int $ A.ActualExpression $ intLiteral 6) A.ValAbbrev A.NameNonce
          [decl' (simpleName "X")
            (A.Rep emptyMeta (A.For emptyMeta (intLiteral 0) (exprVariable "A") (intLiteral 1)))
              A.Original A.NameUser []
          ]
        ]
      ) pullRepCounts 

   ,forAllThree $ \blockType -> testOccamPassTransform "testPullRepCounts 6"
     (nameAndStopCaringPattern "nonce1" "A" . nameAndStopCaringPattern "nonce2" "B")
       (blockType
         [decl' (simpleName "X")
          (A.Rep emptyMeta (A.For emptyMeta (intLiteral 0) (intLiteral 6) (intLiteral 1)))
          A.Original A.NameUser
            [decl' (simpleName "Y")
              (A.Rep emptyMeta (A.For emptyMeta (intLiteral 1) (intLiteral 8) (intLiteral 2)))
                A.Original A.NameUser []
            ]
         ]
       `becomes`
       blockType
         [decl' (simpleName "A")
          (A.Is emptyMeta A.ValAbbrev A.Int $ A.ActualExpression $ intLiteral 6) A.ValAbbrev A.NameNonce
           [decl' (simpleName "X")
            (A.Rep emptyMeta (A.For emptyMeta (intLiteral 0) (exprVariable "A") (intLiteral 1)))
              A.Original A.NameUser
              [decl' (simpleName "B")
                (A.Is emptyMeta A.ValAbbrev A.Int $ A.ActualExpression $ intLiteral 8) A.ValAbbrev A.NameNonce
                  [decl' (simpleName "Y")
                    (A.Rep emptyMeta (A.For emptyMeta (intLiteral 1) (exprVariable "B")
                      (intLiteral 2)))
                      A.Original A.NameUser
                      []
                  ]
              ]
           ]
         ]
      ) pullRepCounts
  ]
  where
    -- Not for PAR any more, that gets pulled up further
    forAllThree :: (forall a. Data a => ([Occ (A.Structured a)] -> Occ A.Process) -> Test) -> Test
    forAllThree f = TestList [f oSEQ, f oALT]
    
    testUnchanged :: Data a => Int -> (A.Structured a -> A.Process) -> Test
    testUnchanged n f = TestCase $ testPass
      ("testPullRepCounts/testUnchanged " ++ show n)
      code
      pullRepCounts code
      (return ())
      where 
        code = (f $ A.Spec emptyMeta (A.Specification emptyMeta (simpleName
          "i") $ A.Rep emptyMeta (A.For emptyMeta (intLiteral 0) (intLiteral 5)
            (intLiteral 1))) $ A.Several emptyMeta [])


testRemoveNesting :: Test
testRemoveNesting = TestList
  [
    test "Blank PROC" $
      oPROC "foo" [] (
        oSKIP
      ) oempty

    , test "Nested PROC" $
      (oPROC "bar" [] (
        oSEQ 
          [decl oINT oX []]
      ) $
      oPROC "foo" [] (
        oSEQ
          [decl oINT oX $
              [oX *:= return (0::Int)
              ,oX *:= return (1::Int)]]
      ) oempty)
      `shouldComeFrom`
      oPROC "foo" [] (
        oSEQ 
          [oPROC "bar" [] (
            oSEQ
              [decl oINT oX []]
          ) $
          decl oINT oX
              [oX *:= return (0::Int)
              ,oX *:= return (1::Int)]]
      ) oempty
  ]
  where
    test :: String -> Occ A.AST -> Test
    test name x = testOccamPass name x removeNesting


--Returns the list of tests:
tests :: Test
tests = TestLabel "PassTest" $ TestList
 [
   testFunctionsToProcs0
   ,testFunctionsToProcs1
   ,testFunctionsToProcs2
   ,testFunctionsToProcs3
   ,testFunctionsToProcs4
   ,testInputCase
   ,testOutExprs
   ,testPullRepCounts
   ,testRemoveNesting
   ,testTransformConstr0
   ,testTransformProtocolInput
 ]


