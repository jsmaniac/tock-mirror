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

-- #ignore-exports

-- | This module contains the tests for the Rain parser.  Some of the code
-- being tested may be invalid at later stages, but we are only testing the
-- parser.  So in fact, it's quite good to check that some invalid code at least
-- makes it past the parser.
--
-- The testing strategy is to take in some text (Rain code), run the parser on it,
-- and check whether the code returned matches a given AST fragment.  The only
-- complication is the Meta tags.  The Meta tags will be generated according to the
-- position of each part of the code.  We don't want to have to work out what the Meta
-- tag will be (what if you inserted a space into the input; you'd have to change the expected
-- result!), and we don't really care.  So we use the pattern stuff from the Pattern, TreeUtil
-- and TestUtil modules to check everything except the meta tags.  
--
-- The "pat" function in this module allows us to write normal AST fragments using "m" (an alias for "emptyMeta")
-- and then turn these into Patterns where any Meta tag that is "m" is ignored during the comparison.
module ParseRainTest (tests) where

import Test.HUnit

{-
import Data.Generics (Data)
import Prelude hiding (fail)
import Test.HUnit
import Text.ParserCombinators.Parsec (runParser,eof)

import qualified AST as A
import CompState
import qualified LexRain as L
import Metadata (Meta,emptyMeta)
import qualified ParseRain as RP
import Pattern
import TagAST
import TestUtils hiding (intLiteral, intLiteralPattern) -- See definitions below
import TreeUtils

data ParseTest a = Show a => ExpPass (String, RP.RainParser a , (a -> Assertion)) | ExpFail (String, RP.RainParser a)

-- | Shorthand for ExpPass
pass :: Show a => (String, RP.RainParser a , (a -> Assertion)) -> ParseTest a
pass x = ExpPass x

-- | Shorthand for ExpFail
fail :: Show a => (String, RP.RainParser a) -> ParseTest a
fail x = ExpFail x

-- | Takes the given AST fragment and returns a Pattern that ignores all the Meta tags in it.
pat :: Data a => a -> Pattern
pat = (stopCaringPattern emptyMeta) . (stopCaringPattern (818181 :: Int)) .
  mkPattern

m :: Meta
m = emptyMeta

inferVarType :: String -> A.Type
inferVarType = A.UnknownVarType (A.TypeRequirements False) . Left . simpleName

inferExpType :: A.Type
inferExpType = A.UnknownVarType (A.TypeRequirements False) $ Right $ (emptyMeta, 818181)

-- In the parser, integer literals have an unknown type:
intLiteral :: Integer -> A.Expression
intLiteral n = integerLiteral (A.UnknownNumLitType emptyMeta 818181 n) n

intLiteralPattern :: Integer -> Pattern
intLiteralPattern = pat . intLiteral

makeListLiteralPattern :: [Pattern] -> Pattern
makeListLiteralPattern items = mLiteral (A.List inferExpType) (mArrayListLiteral $
  mSeveralE items)


-- | Runs a parse test, given a tuple of: (source text, parser function, assertion)
-- There will be success if the parser succeeds, and the output succeeds against the given assertion.
testParsePass :: Show a => (String, RP.RainParser a , (a -> Assertion)) -> Assertion
testParsePass (text,prod,test)
  = do lexOut <- (L.runLexer "<unknown-parse-test>" text)
       case lexOut of
         Left m -> assertFailure $ "Parse error in:\n" ++ text ++ "\n***at: " ++ (show m)
         Right toks -> case (runParser parser emptyState "<test>" toks) of
                         Left error -> assertFailure $  "Parse error in:\n" ++ text ++ "\n***" ++ (show error)
                         Right result -> ((return result) >>= test)
    where parser = do { p <- prod ; eof ; return p}
    --Adding the eof parser above ensures that all the input is consumed from a test.  Otherwise
    --tests such as "seq {}}" would succeed, because the final character simply wouldn't be parsed -
    --which would ruin the point of the test

-- | Checks that a given input fails when the given parser is applied to it.  The assertion
-- will fail if the parser succeeds.
testParseFail :: Show a => (String, RP.RainParser a) -> Assertion
testParseFail (text,prod)
    = do lexOut <- (L.runLexer "<test>" text)
         case lexOut of
           Left error -> return ()
           Right toks -> case (runParser parser emptyState "<test>" toks) of
                           Left error -> return ()
                           Right result -> assertFailure ("Test was expected to fail:\n***BEGIN CODE***\n" ++ text ++ "\n*** END CODE ***\n")
    where parser = do { p <- prod ; eof ; return p}

emptySeveral :: Data a => A.Structured a
emptySeveral = A.Several m []

emptySeveralAST :: A.AST
emptySeveralAST = emptySeveral

-- | A handy synonym for the empty block
emptyBlock :: A.Process
emptyBlock = A.Seq m emptySeveral

--You are allowed to chain arithmetic operators without brackets, but not comparison operators
-- (the meaning of "b == c == d" is obscure enough to be dangerous, even if it passes the type checker)
--All arithmetic operators bind at the same level, which is a closer binding than all comparison operators.
--To clear that up, here's some BNF:
-- expression ::= comparisonExpression | subExpr | dataType ":" expression | "?" expression | "!" expression
-- comparsionExpression ::= subExpr comparisonOp subExpr
-- subExpr ::= exprItem | monadicArithOp subExpr | subExpr dyadicArithOp subExpr | "(" expression ")"
-- exprItem ::= identifier | literal

-- Partially left-factor subExpr:
--subExpr ::= subExpr' | subExpr' dyadicArithOp subExpr
--subExpr' ::= exprItem | monadicArithOp subExpr' | "(" expression ")"


testExprs :: [ParseTest A.Expression]
testExprs =
 [
  --Just a variable:
  passE ("b", -1, Var "b" )

  --Dyadic operators:
  ,passE ("b + c", 0 ,Dy (Var "b") plus (Var "c") )
  ,passE ("b % c", 0 ,Dy (Var "b") A.Rem (Var "c") )
  ,passE ("b == c", 1 ,Dy (Var "b") eq (Var "c") )
  ,passE ("(b + c)", 2 ,Dy (Var "b") plus (Var "c") )
  ,passE ("(b == c)", 3 ,Dy (Var "b") eq (Var "c") )
  ,passE ("((b + c))", 4 ,Dy (Var "b") plus (Var "c") )
  ,passE ("((b == c))", 5 ,Dy (Var "b") eq (Var "c") )
  ,passE ("b - c", 6 ,Dy (Var "b") A.Minus (Var "c" ))
  ,passE ("b + c + d", 7, Dy (Dy (Var "b") plus (Var "c")) plus (Var "d") )
  ,passE ("(b + c) + d", 8, Dy (Dy (Var "b") plus (Var "c")) plus (Var "d") )
  ,passE ("b + (c + d)", 9, Dy (Var "b") plus (Dy (Var "c") plus (Var "d")) )

  ,passE ("b - c * d / e", 10, Dy (Dy (Dy (Var "b") A.Minus (Var "c")) A.Times (Var "d")) A.Div (Var "e") )

  ,passE ("b + c == d * e", 11, Dy (Dy (Var "b") plus (Var "c")) eq (Dy (Var "d") A.Times (Var "e")) )
  ,passE ("(b + c) == d * e", 12, Dy (Dy (Var "b") plus (Var "c")) eq (Dy (Var "d") A.Times (Var "e")) )
  ,passE ("b + c == (d * e)", 13, Dy (Dy (Var "b") plus (Var "c")) eq (Dy (Var "d") A.Times (Var "e")) )
  ,passE ("(b + c) == (d * e)", 14, Dy (Dy (Var "b") plus (Var "c")) eq (Dy (Var "d") A.Times (Var "e")) )
  ,passE ("(b == c) + (d == e)", 15, Dy (Dy (Var "b") eq (Var "c")) plus (Dy (Var "d") eq (Var "e")) )
  ,passE ("(b == c) + d == e", 16, Dy (Dy (Dy (Var "b") eq (Var "c")) plus (Var "d")) eq (Var "e") )
  ,passE ("(b == c) == (d == e)", 17, Dy (Dy (Var "b") eq (Var "c")) eq (Dy (Var "d") eq (Var "e")) )
  ,passE ("(b == c) == d", 18, Dy (Dy (Var "b") eq (Var "c")) eq (Var "d") )

  ,failE ("b == c + d == e")
  ,failE ("b == c == d")
  ,failE ("b < c < d")
  ,failE ("b + c == d + e <= f")

  --Monadic operators:

  ,passE ("-b", 101, Mon A.MonadicMinus (Var "b") )
  ,failE ("+b")
  ,passE ("a - - b", 102, Dy (Var "a") A.Minus (Mon A.MonadicMinus $ Var "b") )
  ,passE ("a--b", 103, Dy (Var "a") A.Minus (Mon A.MonadicMinus $ Var "b") )
  ,passE ("a---b", 104, Dy (Var "a") A.Minus (Mon A.MonadicMinus $ Mon A.MonadicMinus $ Var "b") )
  ,passE ("-b+c", 105, Dy (Mon A.MonadicMinus $ Var "b") plus (Var "c") )
  ,passE ("c+-b", 106, Dy (Var "c") plus (Mon A.MonadicMinus $ Var "b") )
  ,passE ("-(b+c)", 107, Mon A.MonadicMinus $ Dy (Var "b") plus (Var "c") )

  --Casting:

  ,passE ("bool: b", 201, Cast A.Bool (Var "b"))
  ,passE ("mytype: b", 202, Cast (A.UserDataType $ typeName "mytype") (Var "b"))
    --Should at least parse:
  ,passE ("uint8 : true", 203, Cast A.Byte $ Lit (A.True m) )
  ,passE ("uint8 : b == c", 204, Cast A.Byte $ Dy (Var "b") eq (Var "c") )
  ,passE ("uint8 : b + c", 205, Cast A.Byte $ Dy (Var "b") plus (Var "c") )
  ,passE ("uint8 : b + c == d * e", 206, Cast A.Byte $ Dy (Dy (Var "b") plus (Var "c")) eq (Dy (Var "d") A.Times (Var "e")) )
  ,passE ("uint8 : b + (uint8 : c)", 207, Cast A.Byte $ Dy (Var "b") plus (Cast A.Byte $ Var "c") )
  ,passE ("(uint8 : b) + (uint8 : c)", 208, Dy (Cast A.Byte $ Var "b") plus (Cast A.Byte $ Var "c") )
  ,passE ("uint8 : b == (uint8 : c)", 209, Cast A.Byte $ Dy (Var "b") eq (Cast A.Byte $ Var "c") )
  ,passE ("(uint8 : b) == (uint8 : c)", 210, Dy (Cast A.Byte $ Var "b") eq (Cast A.Byte $ Var "c") )
  ,failE ("uint8 : b + uint8 : c")
  ,failE ("uint8 : b == uint8 : c")
  ,failE ("(uint8 : b) + uint8 : c")
  ,failE ("(uint8 : b) == uint8 : c")
  
  ,passE ("?uint8: ?c", 240, Cast (A.ChanEnd A.DirInput A.Unshared A.Byte) $ DirVar A.DirInput "c")
  --Should parse:
  ,passE ("?c: ?c", 241, Cast (A.ChanEnd A.DirInput A.Unshared $ A.UserDataType $ typeName "c") $ DirVar A.DirInput "c")
  ,passE ("?c: ?c : b", 242, Cast (A.ChanEnd A.DirInput A.Unshared $ A.UserDataType $ typeName "c") $ 
                               Cast (A.ChanEnd A.DirInput A.Unshared $ A.UserDataType $ typeName "c") $ Var "b")
  ,failE ("?c:")
  ,failE (":?c")
  
  ,passE ("(48 + (uint8: src % 10)) + r",300,Dy (Dy (Lit $ intLiteral 48) plus (Cast A.Byte $ Dy (Var "src") A.Rem (Lit $ intLiteral 10))) plus (Var "r"))

  -- Function calls:
  ,passE ("foo()", 400, Func "foo" [])
  ,passE ("foo(0)", 401, Func "foo" [Lit $ intLiteral 0])
  ,passE ("foo(0,1,2,3)", 402, Func "foo" $ map (Lit . intLiteral) [0,1,2,3])
  ,passE ("2 + foo()", 403, Dy (Lit $ intLiteral 2) plus $ Func "foo" [])
  ,failE ("foo(")
  ,failE ("foo)")
  ,failE ("foo + 2()")
  ,failE ("[]()")
  ,failE ("()()")
  
 ]
 where
   passE :: (String,Int,ExprHelper) -> ParseTest A.Expression
   passE (code,index,expr) = pass(code,RP.expression,assertPatternMatch ("testExprs " ++ show index)
     (pat $ buildExprPattern expr))
   failE x = fail (x,RP.expression)

   plus = ("+", A.Int, A.Int)
   eq = ("=", A.Int, A.Int)

--TODO add support for shared ? and shared !, as well as any2any channels etc

testLiteral :: [ParseTest A.Expression]
testLiteral =
 [
  --Int literals: 
  pass ("0", RP.literal, assertPatternMatch "testLiteral 0" (intLiteralPattern 0))
  --2^32:
  ,pass ("4294967296", RP.literal, assertPatternMatch "testLiteral 1" (intLiteralPattern 4294967296))
  --2^64:
  ,pass ("18446744073709551616", RP.literal, assertPatternMatch "testLiteral 2" (intLiteralPattern 18446744073709551616))  
  --2^100:  We should be able to parse this, but it will be rejected at a later stage:
  ,pass ("1267650600228229401496703205376", RP.literal, assertPatternMatch "testLiteral 3" (intLiteralPattern 1267650600228229401496703205376))  
  --Test that both literal and expression parse -3 the same way:
  ,pass ("-3", RP.literal, assertPatternMatch "testLiteral 4" (intLiteralPattern (-3)))
  ,pass ("-3", RP.expression, assertPatternMatch "testLiteral 5" (intLiteralPattern (-3)))
  
  --Non-integers currently unsupported:
  ,fail ("0.",RP.literal)
  ,fail ("0.0",RP.literal)
  ,fail (".0",RP.literal)
  ,fail ("0x0",RP.literal)
  ,fail ("0a0",RP.literal)
  ,fail ("0a",RP.literal)
  
  --Identifiers are not literals (except true and false):
  ,pass ("true", RP.literal, assertPatternMatch "testLiteral 100" (pat $ A.True m))
  ,pass ("false", RP.literal, assertPatternMatch "testLiteral 101" (pat $ A.False m))
  ,fail ("x",RP.literal)
  ,fail ("x0",RP.literal)
  ,fail ("TRUE",RP.literal)
  ,fail ("FALSE",RP.literal)
    
  --Strings:
  ,pass ("\"\"", RP.literal, assertPatternMatch "testLiteral 201" $ makeLiteralStringRainPattern "")
  ,pass ("\"abc\"", RP.literal, assertPatternMatch "testLiteral 202" $ makeLiteralStringRainPattern "abc")
  ,pass ("\"abc\\n\"", RP.literal, assertPatternMatch "testLiteral 203" $ makeLiteralStringRainPattern "abc\n")
  ,pass ("\"a\\\"bc\"", RP.literal, assertPatternMatch "testLiteral 204" $ makeLiteralStringRainPattern "a\"bc")
  ,fail ("\"",RP.literal)
  ,fail ("\"\"\"",RP.literal)
  ,fail ("a\"\"",RP.literal)
  ,fail ("\"\"a",RP.literal)
  ,fail ("\"\\\"",RP.literal)
  
  --Characters:
  
  ,pass ("'0'", RP.literal, assertPatternMatch "testLiteral 300" $ makeLiteralCharPattern '0')
  ,pass ("'\\''", RP.literal, assertPatternMatch "testLiteral 301" $ makeLiteralCharPattern '\'')
  ,pass ("'\\n'", RP.literal, assertPatternMatch "testLiteral 302" $ makeLiteralCharPattern '\n')
  ,pass ("'\\\\'", RP.literal, assertPatternMatch "testLiteral 303" $ makeLiteralCharPattern '\\')
  ,fail ("''",RP.literal)
  ,fail ("'",RP.literal)
  ,fail ("'\\",RP.literal)
  ,fail ("'ab'",RP.literal)  
  ,fail ("'\\n\\n'",RP.literal)  

  -- Lists:
  ,pass ("[0]", RP.literal, assertPatternMatch "testLiteral 400" $ pat $
    makeListLiteralPattern [mOnlyE $ intLiteralPattern 0])
  ,pass ("[]", RP.literal, assertPatternMatch "testLiteral 401" $ pat $ 
    makeListLiteralPattern [])
  ,pass ("[0,1,2]", RP.literal, assertPatternMatch "testLiteral 402" $ pat $
    makeListLiteralPattern $ map (mOnlyE . intLiteralPattern) [0,1,2])
  ,pass ("['0']", RP.literal, assertPatternMatch "testLiteral 403" $ pat $
    makeListLiteralPattern [mOnlyE $ makeLiteralCharPattern '0'])

  ,fail ("[", RP.literal)
  ,fail ("]", RP.literal)
  ,fail ("[,]", RP.literal)
  ,fail ("[0,]", RP.literal)
  ,fail ("[,0]", RP.literal)
  ,fail ("[0,,1]", RP.literal)
 ]

testRange :: [ParseTest A.Expression]
testRange =
 [
  pass("[0..1]", RP.expression, assertPatternMatch "testRange 0" $ pat $
    A.Literal m (A.List inferExpType) $ A.RangeLiteral m (intLiteral 0) (intLiteral 1))
  ,pass("[0..10000]", RP.expression, assertPatternMatch "testRange 1" $ pat $
    A.Literal m (A.List inferExpType) $ A.RangeLiteral m (intLiteral 0) (intLiteral 10000))
  ,pass("[-3..-1]", RP.expression, assertPatternMatch "testRange 2" $ pat $
    A.Literal m (A.List inferExpType) $ A.RangeLiteral m (intLiteral $ -3) (intLiteral $ -1))
  ,pass("[sint16: 0..1]", RP.expression, rangePattern 4 (A.List A.Int16)
    (buildExprPattern $ Cast A.Int16 (Lit $ intLiteral 0))
    (buildExprPattern $ Cast A.Int16 (Lit $ intLiteral 1)))
  
  --For now, at least, this should fail:
  ,fail("[0..x]", RP.expression)
 ]
 where
   rangePattern :: Int -> A.Type -> Pattern -> Pattern -> (A.Expression -> Assertion)
   rangePattern n t start end = assertPatternMatch ("testRange " ++ show n) $
     pat $ mLiteral t $ mRangeLiteral start end


--Helper function for ifs:
makeIf :: [(A.Expression,A.Process)] -> A.Process
makeIf list = A.If m $ A.Several m (map makeChoice list)
  where
    makeChoice :: (A.Expression,A.Process) -> A.Structured A.Choice
    makeChoice (exp,proc) = A.Only m $ A.Choice m exp proc

dyExp :: A.DyadicOp -> A.Variable -> A.Variable -> A.Expression
dyExp op v0 v1 = A.Dyadic m op (A.ExprVariable m v0) (A.ExprVariable m v1)

testIf :: [ParseTest A.Process]
testIf =
 [
  passIf ("if (a) {}", 0, [(exprVariable "a",emptyBlock),(A.True m,A.Skip m)])
  ,passIf ("if (a) {} else {}", 1, [(exprVariable "a",emptyBlock),(A.True m,emptyBlock)])
  ,passIf ("if (a) {} else {a = b;}", 2, [(exprVariable "a",emptyBlock),(A.True m,makeSeq [makeSimpleAssign "a" "b"])])
  ,passIf ("if (a) {} else {if (b) {} }", 3,
    [(exprVariable "a",emptyBlock),(A.True m,makeSeq [makeIf [(exprVariable "b",emptyBlock),(A.True m,A.Skip m)]])])
  ,passIf ("if (a) {} else {if (b) {} else {} }", 4,
    [(exprVariable "a",emptyBlock),(A.True m,makeSeq [makeIf [(exprVariable "b",emptyBlock),(A.True m,emptyBlock)]])])
  ,passIf ("if (a) {c = d;} else {if (b) {e = f;} else par {g = h;}}", 5,
    [(exprVariable "a",makeSeq [makeSimpleAssign "c" "d"]),(A.True m,makeSeq [makeIf [(exprVariable "b",makeSeq [makeSimpleAssign "e" "f"]),(A.True m,makePar [makeSimpleAssign "g" "h"])]])])
  ,fail ("if (a) c = d;",RP.statement)
  ,fail ("if (a) {c = d;} else e = f;",RP.statement)
  ,fail ("if (a) {c = d;} else if (b) {e = f;}",RP.statement)
  ,fail ("if (a) {} else { if (b) {} } else {} ",RP.statement)
 ]
 where
  passIf :: (String, Int, [(A.Expression,A.Process)]) -> ParseTest A.Process
  passIf (input,ind,exp) = pass (input, RP.statement, assertPatternMatch ("testIf " ++ show ind) (pat $ makeIf exp))

testAssign :: [ParseTest A.Process]
testAssign =
 [
  pass ("a = b;",RP.statement,
    assertPatternMatch "Assign Test 0" $ makeSimpleAssignPattern "a" "b")
  ,fail ("a != b;",RP.statement)
  ,pass ("a += b;",RP.statement,
    assertPatternMatch "Assign Test 1" $ pat $ makeAssign (variable "a") (dyExp A.Plus (variable ("a")) (variable ("b")) ) )
  ,fail ("a + = b;",RP.statement)
 ]

testWhile :: [ParseTest A.Process]
testWhile = 
 [
  pass ("while (a) {}",RP.statement, 
        assertPatternMatch "While Test" $ pat $ A.While emptyMeta (exprVariable "a") (emptyBlock) )
  ,fail ("while (a)",RP.statement)
  ,fail ("while () ;",RP.statement)
  ,fail ("while () {}",RP.statement)
  ,fail ("while ;",RP.statement)
  ,fail ("while {}",RP.statement)
  ,fail ("while ",RP.statement)
 ]

testSeq :: [ParseTest A.Process]
testSeq =
 [
   passSeq (0, "seq { }", emptyBlock )
  ,fail ("seq { ; ; }",RP.statement)

  ,passSeq (1, "{ }", emptyBlock )

  ,fail ("{ ; ; }",RP.statement)

  ,passSeq (2, "{ { } }", makeSeq [emptyBlock] )
  ,passSeq (3, "seq { { } }", makeSeq [emptyBlock] )
  ,passSeq (4, "{ seq { } }", makeSeq [emptyBlock] )

  ,fail ("seq",RP.statement)
  ,fail ("seq ;",RP.statement)
  ,fail ("seq {",RP.statement)
  ,fail ("seq }",RP.statement)
  ,fail ("{",RP.statement)
  ,fail ("}",RP.statement)
  ,fail ("seq seq {}",RP.statement)
  ,fail ("seq seq",RP.statement)  
  ,fail ("seq {}}",RP.statement)
  ,fail ("seq {{}",RP.statement)
  --should fail, because it is two statements, not one:
  ,fail ("seq {};",RP.statement)
  ,fail ("{};",RP.statement)
  
 ]
 where
   passSeq :: (Int, String, A.Process) -> ParseTest A.Process
   passSeq (ind, input, exp) = pass (input,RP.statement, assertPatternMatch ("testSeq " ++ show ind) (pat exp))

testPar :: [ParseTest A.Process]
testPar =
 [
   passPar (0, "par { }", A.Par m A.PlainPar $ A.Several m [] )

  ,passPar (1, "par { {} {} }", A.Par m A.PlainPar $ A.Several m [A.Only m emptyBlock, A.Only m emptyBlock] )

  --Rain only allows declarations at the beginning of a par block:

  ,passPar (2, "par {int:x; {} }", A.Par m A.PlainPar $ 
    A.Spec m (A.Specification m (simpleName "x") $ A.Declaration m A.Int) $
    A.Several m [A.Only m $ A.Seq m $ A.Several m []] )
      

  ,passPar (3, "par {uint16:x; uint32:y; {} }", A.Par m A.PlainPar $ 
      A.Spec m (A.Specification m (simpleName "x") $ A.Declaration m A.UInt16) $ 
      A.Spec m (A.Specification m (simpleName "y") $ A.Declaration m A.UInt32) $ 
      A.Several m [A.Only m $ A.Seq m $ A.Several m []] )
      
  ,fail ("par { {} int: x; }",RP.statement)
 ]
 where
   passPar :: (Int, String, A.Process) -> ParseTest A.Process
   passPar (ind, input, exp) = pass (input,RP.statement, assertPatternMatch ("testPar " ++ show ind) (pat exp))

-- | Test innerBlock, particularly with declarations mixed with statements:
testBlock :: [ParseTest (A.Structured A.Process)]
testBlock =
 [
   passBlock (0, "{ a = b; }", False, A.Several m [A.Only m $ makeSimpleAssign "a" "b"])
   
  ,passBlock (1, "{ a = b; b = c; }", False,
    A.Several m [A.Only m $ makeSimpleAssign "a" "b",A.Only m $ makeSimpleAssign "b" "c"])
    
  ,passBlock (2, "{ uint8: x; a = b; }", False,
    A.Spec m (A.Specification m (simpleName "x") $ A.Declaration m A.Byte) $
      A.Several m [A.Only m $ makeSimpleAssign "a" "b"])
  
  ,passBlock (3, "{ uint8: x; a = b; b = c; }", False,
    A.Spec m (A.Specification m (simpleName "x") $ A.Declaration m A.Byte) $
      A.Several m [A.Only m $ makeSimpleAssign "a" "b",A.Only m $ makeSimpleAssign "b" "c"])

  ,passBlock (4, "{ b = c; uint8: x; a = b; }", False,
    A.Several m [A.Only m $ makeSimpleAssign "b" "c",
      A.Spec m (A.Specification m (simpleName "x") $ A.Declaration m A.Byte) $
        A.Several m [A.Only m $ makeSimpleAssign "a" "b"]
    ])

  ,passBlock (5, "{ uint8: x; }", False,
    A.Spec m (A.Specification m (simpleName "x") $ A.Declaration m A.Byte) emptySeveral)

  ,fail("{b}",RP.innerBlock False Nothing)
 ]
 where
   passBlock :: (Int, String, Bool, A.Structured A.Process) -> ParseTest (A.Structured A.Process)
   passBlock (ind, input, b, exp) = pass (input, RP.innerBlock b Nothing, assertPatternMatch ("testBlock " ++ show ind) (pat exp))
        
testEach :: [ParseTest A.Process]
testEach =
 [
  pass ("seqeach (c : \"1\") par {c = 7;}", RP.statement,
    assertPatternMatch  "Each Test 0" (pat $ A.Seq m $ A.Spec m (A.Specification
      m (simpleName "c") $ A.Rep m (A.ForEach m (makeLiteralStringRain "1"))) $
      A.Only m $ makePar [makeAssign (variable "c") (intLiteral 7)] ))
  ,pass ("pareach (c : \"345\") {c = 1; c = 2;}", RP.statement,
    assertPatternMatch "Each Test 1" $ pat $ A.Par m A.PlainPar $ A.Spec m
      (A.Specification m (simpleName "c") $ A.Rep m (A.ForEach m (makeLiteralStringRain "345"))) $ 
      A.Only m $ makeSeq[makeAssign (variable "c") (intLiteral 1),makeAssign (variable "c") (intLiteral 2)] )      
 ]

testTopLevelDecl :: [ParseTest A.AST]
testTopLevelDecl =
 [
  passTop (0, "process noargs() {}", 
    [A.Spec m (A.Specification m (simpleName "noargs") $ A.Proc m (A.PlainSpec, A.Recursive) [] jemptyBlock) emptySeveral])
  
  ,passTop (1, "process onearg(int: x) {x = 0;}",
    [A.Spec m (A.Specification m (simpleName "onearg") $ A.Proc m (A.PlainSpec, A.Recursive)
      [A.Formal A.ValAbbrev A.Int (simpleName "x")] $ Just $
      makeSeq [makeAssign (variable "x") (intLiteral 0)])
      emptySeveral
    ])
    
  ,passTop (2, "process noargs0() {} process noargs1 () {}",
    [A.Spec m (A.Specification m (simpleName "noargs0") $ A.Proc m (A.PlainSpec, A.Recursive) [] jemptyBlock) emptySeveral 
    ,A.Spec m (A.Specification m (simpleName "noargs1") $ A.Proc m (A.PlainSpec, A.Recursive) [] jemptyBlock) emptySeveral])

  ,passTop (4, "process noargs() par {}",
    [A.Spec m (A.Specification m (simpleName "noargs") $ A.Proc m (A.PlainSpec, A.Recursive) [] $
      Just $ A.Par m A.PlainPar emptySeveral) emptySeveral])

  , fail ("process", RP.topLevelDecl)
  , fail ("process () {}", RP.topLevelDecl)
  , fail ("process foo", RP.topLevelDecl)
  , fail ("process foo ()", RP.topLevelDecl)
  , fail ("process foo () {", RP.topLevelDecl)
  , fail ("process foo ( {} )", RP.topLevelDecl)
  , fail ("process foo (int: x)", RP.topLevelDecl)
  , fail ("process foo (int x) {}", RP.topLevelDecl)
    
  ,passTop (100, "function uint8: cons() {}",
    [A.Spec m (A.Specification m (simpleName "cons") $ A.Function m (A.PlainSpec,A.Recursive) [A.Byte] []
      $ Just $ Right emptyBlock) emptySeveral])

  ,passTop (101, "function uint8: f(uint8: x) {}",
    [A.Spec m (A.Specification m (simpleName "f") $
      A.Function m (A.PlainSpec, A.Recursive) [A.Byte] [A.Formal A.ValAbbrev A.Byte (simpleName "x")]
        $ Just $ Right emptyBlock)
      emptySeveral])

  ,passTop (102, "function uint8: id(uint8: x) {return x;}",
    [A.Spec m (A.Specification m (simpleName "id") $
      A.Function m (A.PlainSpec, A.Recursive) [A.Byte] [A.Formal A.ValAbbrev A.Byte (simpleName "x")] $ Just $ Right $
        A.Seq m $ A.Several m [A.Only m $ A.Assign m [variable "id"] (A.ExpressionList m [exprVariable "x"])])
      emptySeveral])
 ]
 where
   passTop :: (Int, String, [A.AST]) -> ParseTest A.AST
   passTop (ind, input, exp) = pass (input, RP.topLevelDecl, assertPatternMatch ("testTopLevelDecl " ++ show ind) $ pat $ A.Several m exp)
   jemptyBlock = Just emptyBlock

nonShared :: A.ChanAttributes
nonShared = A.ChanAttributes { A.caWritingShared = A.Unshared, A.caReadingShared = A.Unshared}

testDataType :: [ParseTest A.Type]
testDataType =
 [
  pass ("bool",RP.dataType,assertEqual "testDataType 0" A.Bool)
  ,pass ("int",RP.dataType,assertEqual "testDataType 1" A.Int)
  ,pass ("uint8",RP.dataType,assertEqual "testDataType 2" A.Byte)
  ,pass ("uint16",RP.dataType,assertEqual "testDataType 3" A.UInt16)
  ,pass ("uint32",RP.dataType,assertEqual "testDataType 4" A.UInt32)
  ,pass ("uint64",RP.dataType,assertEqual "testDataType 5" A.UInt64)
  ,pass ("sint8",RP.dataType,assertEqual "testDataType 6" A.Int8)
  ,pass ("sint16",RP.dataType,assertEqual "testDataType 7" A.Int16)
  ,pass ("sint32",RP.dataType,assertEqual "testDataType 8" A.Int32)
  ,pass ("sint64",RP.dataType,assertEqual "testDataType 9" A.Int64)
  ,pass ("boolean",RP.dataType,assertEqual "testDataType 10" $ A.UserDataType $ typeName "boolean")
  ,pass ("uint24",RP.dataType,assertEqual "testDataType 11" $ A.UserDataType $ typeName "uint24")
  ,pass ("int0",RP.dataType,assertEqual "testDataType 12" $ A.UserDataType $ typeName "int0")
  ,fail ("bool bool",RP.dataType)
  
  ,pass ("?int",RP.dataType,assertEqual "testDataType 102" $ A.ChanEnd A.DirInput A.Unshared A.Int)
  ,pass ("! bool",RP.dataType,assertEqual "testDataType 103" $ A.ChanEnd A.DirOutput A.Unshared A.Bool)
  --These types should succeed in the *parser* -- they would be thrown out further down the line:
  ,pass ("??int",RP.dataType,assertEqual "testDataType 104" $ A.ChanEnd A.DirInput A.Unshared $ A.ChanEnd A.DirInput A.Unshared A.Int)
  ,pass ("? ? int",RP.dataType,assertEqual "testDataType 105" $ A.ChanEnd A.DirInput A.Unshared $ A.ChanEnd A.DirInput A.Unshared A.Int)
  ,pass ("!!bool",RP.dataType,assertEqual "testDataType 106" $ A.ChanEnd A.DirOutput A.Unshared $ A.ChanEnd A.DirOutput A.Unshared A.Bool)
  ,pass ("?!bool",RP.dataType,assertEqual "testDataType 107" $ A.ChanEnd A.DirInput A.Unshared $ A.ChanEnd A.DirOutput A.Unshared A.Bool)
  
  ,fail ("?",RP.dataType)
  ,fail ("!",RP.dataType)
  ,fail ("??",RP.dataType)
  ,fail ("int?",RP.dataType)
  ,fail ("bool!",RP.dataType)
  ,fail ("int?int",RP.dataType)  
  
  ,pass ("channel bool",RP.dataType,assertEqual "testDataType 200" $ A.Chan nonShared A.Bool)
  
  ,pass ("time",RP.dataType,assertEqual "testDataType 300" A.Time)
  ,pass ("timer",RP.dataType,assertEqual "testDataType 301" $ A.UserDataType $ typeName "timer")

  ,pass ("[int]",RP.dataType, assertEqual "testDataType 400" $ A.List A.Int)
  ,pass ("[uint8]",RP.dataType, assertEqual "testDataType 401" $ A.List A.Byte)
  ,pass ("[foo]",RP.dataType, assertEqual "testDataType 402" $ A.List
    $ A.UserDataType $ typeName "foo")
 ]
 
instance Data a => Show (A.Structured a -> A.Structured a) where
  show _ = "<function over Structured"
 
testDecl :: [ParseTest (Meta, A.AST -> A.AST)]
testDecl =
 [
  passd ("bool: b;",0,pat $ A.Specification m (simpleName "b") $ A.Declaration m A.Bool)
  ,passd ("uint8: x;",1,pat $ A.Specification m (simpleName "x") $ A.Declaration m A.Byte)
  ,passd ("?bool: bc;",2,pat $ A.Specification m (simpleName "bc") $ A.Declaration m (A.ChanEnd A.DirInput A.Unshared A.Bool))
  ,passd ("a: b;",3,pat $ A.Specification m (simpleName "b") $ A.Declaration m (A.UserDataType $ A.Name m "a"))

  ,passd2 ("bool: b0,b1;",100,pat $ A.Specification m (simpleName "b0") $ A.Declaration m A.Bool,
                              pat $ A.Specification m (simpleName "b1") $ A.Declaration m A.Bool)
  
  
  ,fail ("bool:;",RP.declaration)
  ,fail ("bool;",RP.declaration)
  ,fail (":b;",RP.declaration)
  ,fail ("bool:b",RP.declaration)
  ,fail ("bool b",RP.declaration)
  ,fail ("bool b;",RP.declaration)
  ,fail ("bool:?b;",RP.declaration)
  ,fail ("bool:b,;",RP.declaration)
  ,fail ("bool: b0 b1;",RP.declaration)
 ]
 where
   specAST = (A.Spec :: Meta -> A.Specification -> A.AST -> A.AST)
 
   passd :: (String,Int,Pattern) -> ParseTest (Meta, A.AST -> A.AST)
   passd (code,index,exp) = pass(code,RP.declaration,check ("testDecl " ++ (show index)) exp)
   check :: String -> Pattern -> (Meta, A.AST -> A.AST) -> Assertion
   check msg spec (_,act) = assertPatternMatch msg (tag3 specAST DontCare spec $ emptySeveralAST) (act $ emptySeveralAST)

   passd2 :: (String,Int,Pattern,Pattern) -> ParseTest (Meta, A.AST -> A.AST)
   passd2 (code,index,expOuter,expInner) = pass(code,RP.declaration,check2 ("testDecl " ++ (show index)) expOuter expInner)
   check2 :: String -> Pattern -> Pattern -> (Meta, A.AST -> A.AST) -> Assertion
   check2 msg specOuter specInner (_,act) = assertPatternMatch msg (tag3 specAST DontCare specOuter $ tag3 specAST DontCare specInner $ emptySeveralAST) (act $ emptySeveralAST)

testComm :: [ParseTest A.Process]
testComm =
 [
  --Output:
  pass ("c ! x;",RP.statement,assertPatternMatch "testComm 0" $ pat $ A.Output m (variable "c") [A.OutExpression m (exprVariable "x")])
  ,pass ("c!x;",RP.statement,assertPatternMatch "testComm 1" $ pat $ A.Output m (variable "c") [A.OutExpression m (exprVariable "x")])
  ,pass ("c!0+x;",RP.statement,assertPatternMatch "testComm 2" $ pat $ A.Output m (variable "c") [A.OutExpression m $ A.Dyadic m A.Plus (intLiteral 0) (exprVariable "x")])
  ,pass ("c!!x;",RP.statement,assertPatternMatch "testComm 3" $ pat $ A.Output m (variable "c") [A.OutExpression m $ (exprDirVariable A.DirOutput "x")])
  ,fail ("c!x",RP.statement)
  ,fail ("c!x!y;",RP.statement)  
  ,fail ("c!x,y;",RP.statement)
  ,fail ("c!;",RP.statement)
  ,fail ("!x;",RP.statement)

  --Input:
  ,pass ("c ? x;",RP.statement, assertPatternMatch "testComm 100" $ pat $ A.Input m (variable "c") $ A.InputSimple m [A.InVariable m (variable "x")])
  ,pass ("c?x;",RP.statement, assertPatternMatch "testComm 101" $ pat $ A.Input m (variable "c") $ A.InputSimple m [A.InVariable m (variable "x")])
  --Later will probably become the extended rendezvous syntax:
  ,pass ("c??x;",RP.statement, assertPatternMatch "testComm 101" $ pat $ A.Input m (variable "c") $ A.InputSimple m [A.InVariable m (A.DirectedVariable m A.DirInput $ variable "x")])
  ,fail ("c ? x + 0;",RP.statement)
  ,fail ("?x;",RP.statement)
  ,fail ("c ? x",RP.statement)
  ,fail ("c ? ;",RP.statement)
  ,fail ("c ? x ? y;",RP.statement)
  ,fail ("c ? x , y;",RP.statement)  
 ]

testAlt :: [ParseTest A.Process]
testAlt =
 [
   passAlt (0, "pri alt {}", A.Alt m True $ A.Several m [])
  ,passAlt (1, "pri alt { c ? x {} }", A.Alt m True $ A.Several m [A.Only m $ A.Alternative m 
    (A.True m) (variable "c") (A.InputSimple m [A.InVariable m (variable "x")]) emptyBlock])
  ,passAlt (2, "pri alt { c ? x {} d ? y {} }", A.Alt m True $ A.Several m [
    A.Only m $ A.Alternative m (A.True m) (variable "c") (A.InputSimple m [A.InVariable m (variable "x")]) emptyBlock
    ,A.Only m $ A.Alternative m (A.True m) (variable "d") (A.InputSimple m [A.InVariable m (variable "y")]) emptyBlock])
  --Fairly nonsensical, but valid:
  ,passAlt (3, "pri alt { else {} }", A.Alt m True $ A.Several m [
    A.Only m $ A.AlternativeSkip m (A.True m) emptyBlock])
  ,passAlt (4, "pri alt { c ? x {} else {} }", A.Alt m True $ A.Several m [
    A.Only m $ A.Alternative m (A.True m) (variable "c") (A.InputSimple m [A.InVariable m (variable "x")]) emptyBlock
    ,A.Only m $ A.AlternativeSkip m (A.True m) emptyBlock])
  
  ,passAlt (100, "pri alt { wait for t {} }", A.Alt m True $ A.Several m [
    A.Only m $ A.Alternative m (A.True m) timer (A.InputTimerFor m $ exprVariable "t") emptyBlock])
  ,passAlt (101, "pri alt { wait for t {} wait until t {} }", A.Alt m True $ A.Several m [
    A.Only m $ A.Alternative m (A.True m) timer (A.InputTimerFor m $ exprVariable "t") emptyBlock
    ,A.Only m $ A.Alternative m (A.True m) timer (A.InputTimerAfter m $ exprVariable "t") emptyBlock])
  ,passAlt (102, "pri alt { wait until t + t {} else {} }", A.Alt m True $ A.Several m [
    A.Only m $ A.Alternative m (A.True m) timer (A.InputTimerAfter m (buildExpr $ Dy (Var "t") A.Plus (Var "t"))) emptyBlock
    ,A.Only m $ A.AlternativeSkip m (A.True m) emptyBlock])


    
  ,fail("pri {}",RP.statement)
  ,fail("alt {}",RP.statement)
  ,fail("pri alt ;",RP.statement)
  ,fail("pri alt {",RP.statement)
  ,fail("pri alt }",RP.statement)
  ,fail("pri alt { c ? x }",RP.statement)
  ,fail("pri alt { c ? x ; }",RP.statement)
  ,fail("pri alt { c ? x {}; }",RP.statement)
  ,fail("pri alt { c ! x {} }",RP.statement)
  ,fail("pri alt { {} }",RP.statement)
  ,fail("pri alt { c = x {} }",RP.statement)
  ,fail("pri alt { else {} c ? x {} }",RP.statement)
  ,fail("pri alt { d ? y {} else {} c ? x {} }",RP.statement)
  ,fail("pri alt { else {} else {} }",RP.statement)
  ,fail("pri alt { d ? y {} else {} c ? x {} else {} }",RP.statement)
  ,fail("pri alt { wait for {} }",RP.statement)
  ,fail("pri alt { wait until t; {} }",RP.statement)
  ,fail("pri alt { wait t {} }",RP.statement)
  ,fail("pri alt { for t {} }",RP.statement)
  
 ]
 where
   timer = A.Variable m RP.rainTimerName
   passAlt :: (Int, String, A.Process) -> ParseTest A.Process
   passAlt (ind, input, exp) = pass (input, RP.statement, assertPatternMatch ("testAlt " ++ show ind) (pat exp))

testRun :: [ParseTest A.Process]
testRun =
 [
  pass ("foo();",RP.statement,assertPatternMatch "testRun 1" $ tag3 A.ProcCall DontCare (procNamePattern "foo") ([] :: [A.Actual]))
  ,pass ("foo(c);",RP.statement,assertPatternMatch "testRun 2" $ tag3 A.ProcCall DontCare (procNamePattern "foo") 
    [tag1 A.ActualVariable (variablePattern "c")])
  ,pass ("foo(c,0+x);",RP.statement,assertPatternMatch "testRun 3" $ tag3 A.ProcCall DontCare (procNamePattern "foo")
    [tag1 A.ActualVariable (variablePattern "c"),tag1 A.ActualExpression $ tag4 A.Dyadic DontCare A.Plus (intLiteralPattern 0) (exprVariablePattern "x")])  
  ,fail ("",RP.statement)
  ,fail (";",RP.statement)
  ,fail ("();",RP.statement)
  ,fail ("foo()",RP.statement)
  ,fail ("foo(,);",RP.statement)
  
 ]

testTime :: [ParseTest A.Process]
testTime =
 [
  pass ("now t;",RP.statement, assertPatternMatch "testTime 0" $
    mInput timer $ mInputTimerRead (mInVariable $ variablePattern "t"))
  ,fail ("now t",RP.statement)
  ,fail ("now ;",RP.statement)
  ,fail ("now t + t;",RP.statement)
  
  ,pass ("wait for t;",RP.statement, assertPatternMatch "testTime 1" $
    mInput timer $ mInputTimerFor (exprVariablePattern "t"))
  ,pass ("wait until t;",RP.statement, assertPatternMatch "testTime 2" $
    mInput timer $ mInputTimerAfter (exprVariablePattern "t"))
  ,pass ("wait until t + t;",RP.statement, assertPatternMatch "testTime 3" $
    mInput timer $ mInputTimerAfter $ buildExprPattern $ Dy (Var "t") A.Plus (Var "t"))
  ,fail ("waitfor t;",RP.statement)
  ,fail ("waituntil t;",RP.statement)
  ,fail ("wait for t",RP.statement)
  ,fail ("until t;",RP.statement)
 ]
 where
   timer = mVariable RP.rainTimerName

testPoison :: [ParseTest A.Process]
testPoison =
 [
  pass ("poison x;", RP.statement, assertPatternMatch "testPoison 0" $
    mInjectPoison $ variablePattern "x")
  ,fail ("poison 0;", RP.statement)
  ,fail ("poison 0", RP.statement)
  ,fail ("poison;", RP.statement)
  ,fail ("poison", RP.statement)
 ]
-}

--Returns the list of tests:
tests :: Test
tests = TestLabel "ParseRainTest" $ TestList
 [] {-
  parseTests testExprs,
  parseTests testLiteral,
  parseTests testRange,
  parseTests testWhile,
  parseTests testSeq,
  parseTests testPar,
  parseTests testBlock,
  parseTests testEach,
  parseTests testIf,
  parseTests testAssign,
  parseTests testDataType,
  parseTests testComm,
  parseTests testAlt,
  parseTests testTime,
  parseTests testRun,
  parseTests testDecl,
  parseTests testPoison,
  parseTests testTopLevelDecl
 ] -}
--TODO test:
-- input (incl. ext input)
--TODO later on:
-- types (lists, tuples, maps)
-- functions
-- typedefs

{-
  where
    parseTest :: Show a => ParseTest a -> Test
    parseTest (ExpPass test) = TestCase (testParsePass test)
    parseTest (ExpFail test) = TestCase (testParseFail test)
    parseTests :: Show a => [ParseTest a] -> Test
    parseTests tests = TestList (map parseTest tests)
-}
