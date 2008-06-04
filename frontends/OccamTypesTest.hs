{-
Tock: a compiler for parallel languages
Copyright (C) 2008  University of Kent

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

-- | Tests for 'OccamTypes'.
module OccamTypesTest (ioTests) where

import Control.Monad.State
import Data.Generics
import Test.HUnit hiding (State)

import qualified AST as A
import CompState
import Metadata
import qualified OccamTypes
import TestHarness
import TestUtils

m :: Meta
m = emptyMeta

-- | Initial state for the tests.
startState :: State CompState ()
startState
    =  do defineConst "constInt" A.Int (intLiteral 2)
          defineConst "constInts" intsT (A.Literal m intsT arrayLit)
          defineVariable "varInt" A.Int
          defineVariable "varByte" A.Byte
          defineVariable "varReal" A.Real32
          defineVariable "varInts" (A.Array [A.UnknownDimension] A.Int)
          defineVariable "varBytes" (A.Array [A.UnknownDimension] A.Byte)
          defineUserDataType "MYINT" A.Int
          defineUserDataType "MY2INT" (A.Array [dimension 2] A.Int)
          defineRecordType "COORD2" [("x", A.Int), ("y", A.Int)]
          defineRecordType "COORD3" [("x", A.Real32), ("y", A.Real32),
                                     ("z", A.Real32)]
          defineChannel "chanInt" chanIntT
          defineChannel "chansInt" (A.Array [A.UnknownDimension] chanIntT)
          defineVariable "mobileInt" (A.Mobile A.Int)
          defineFunction "function0" [A.Int] []
          defineFunction "function1" [A.Int] [("x", A.Int)]
          defineFunction "function2" [A.Int] [("x", A.Int), ("y", A.Int)]
          defineFunction "function22" [A.Int, A.Int]
                                      [("x", A.Int), ("y", A.Int)]
          defineProtocol "countedInts" $ [A.Counted A.Int intsT]
          defineChannel "chanCountedInts" countedIntsT
          defineProtocol "iir" $ [A.Int, A.Int, A.Real32]
          defineChannel "chanIIR" iirT
          defineProtocolCase "caseProto" $ [ (simpleName "one", [A.Int])
                                           , (simpleName "two", [A.Real32])
                                           , (simpleName "three", [])
                                           ]
          defineChannel "chanCaseProto" caseProtoT
          defineTimer "tim" $ A.Timer A.OccamTimer
          defineProc "proc0" []
          defineProc "proc1" [("x", A.ValAbbrev, A.Int)]
          defineProc "proc2" [("x", A.ValAbbrev, A.Int), ("y", A.Abbrev, A.Int)]
  where
    intsT = A.Array [A.UnknownDimension] A.Int
    arrayLit = A.ArrayLiteral m []
    chanT t = A.Chan A.DirUnknown (A.ChanAttributes False False) t
    chanIntT = chanT A.Int
    countedIntsT = chanT $ A.UserProtocol (simpleName "countedInts")
    iirT = chanT $ A.UserProtocol (simpleName "iir")
    caseProtoT = chanT $ A.UserProtocol (simpleName "caseProto")

-- | Test the typechecker.
testOccamTypes :: Test
testOccamTypes = TestList
    [
    --{{{  expressions

    -- Subscript expressions
      testOK     0 $ subex $ A.Subscript m A.NoCheck intE
    , testFail   1 $ subex $ A.Subscript m A.NoCheck byteE
    , testOK     2 $ subex $ A.SubscriptFromFor m A.NoCheck intE intE
    , testFail   3 $ subex $ A.SubscriptFromFor m A.NoCheck byteE byteE
    , testOK     4 $ subex $ A.SubscriptFrom m A.NoCheck intE
    , testFail   5 $ subex $ A.SubscriptFrom m A.NoCheck byteE
    , testOK     6 $ subex $ A.SubscriptFor m A.NoCheck intE
    , testFail   7 $ subex $ A.SubscriptFor m A.NoCheck byteE

    -- Trivial literals
    , testOK    20 $ intE
    , testOK    21 $ byteE

    -- Array literals
    , testOK    30 $ A.Literal m twoIntsT twoInts
    , testFail  31 $ A.Literal m threeIntsT twoInts
    , testFail  32 $ A.Literal m twoBytesT twoInts
    , testFail  33 $ A.Literal m A.Int twoInts
    , testFail  34 $ A.Literal m twoTwoIntsT twoInts
    , testOK    35 $ A.Literal m myTwoIntsT twoInts
    , testFail  36 $ A.Literal m myIntT twoInts

    -- Record literals
    , testFail  40 $ A.Literal m coord2T twoInts
    , testOK    41 $ A.Literal m coord2T coord2
    , testFail  42 $ A.Literal m coord2T coord3
    , testOK    43 $ A.Literal m coord3T coord3
    , testFail  44 $ A.Literal m coord3T coord2
    , testFail  45 $ A.Literal m A.Int coord2
    , testFail  46 $ A.Literal m twoIntsT coord2
    , testFail  47 $ A.Literal m myTwoIntsT coord2

    -- Variables
    , testOK    50 $ intV
    , testOK    51 $ bytesV
    , testOK    52 $ A.DirectedVariable m A.DirInput intC
    , testFail  53 $ A.DirectedVariable m A.DirInput intV
    , testOK    54 $ A.DerefVariable m mobileIntV
    , testFail  55 $ A.DerefVariable m intC

    -- Operators in expressions
    , testOK   100 $ A.Monadic m A.MonadicSubtr intE
    , testFail 101 $ A.Monadic m A.MonadicSubtr twoIntsE
    , testFail 102 $ A.Monadic m A.MonadicSubtr boolE
    , testFail 103 $ A.Monadic m A.MonadicNot intE
    , testOK   104 $ A.Monadic m A.MonadicNot boolE
    , testOK   105 $ A.Dyadic m A.Add intE intE
    , testFail 106 $ A.Dyadic m A.Add intE byteE
    , testFail 107 $ A.Dyadic m A.Add byteE intE
    , testFail 108 $ A.Dyadic m A.Add byteE boolE
    , testOK   109 $ A.Dyadic m A.LeftShift intE intE
    , testOK   110 $ A.Dyadic m A.LeftShift byteE intE
    , testFail 111 $ A.Dyadic m A.LeftShift intE byteE
    , testOK   112 $ A.Dyadic m A.And boolE boolE
    , testFail 113 $ A.Dyadic m A.And boolE intE
    , testFail 114 $ A.Dyadic m A.And intE boolE
    , testFail 115 $ A.Dyadic m A.Add twoIntsE twoIntsE
    , testOK   116 $ A.Dyadic m A.Concat listE listE
    , testFail 117 $ A.Dyadic m A.Concat listE intE
    , testFail 118 $ A.Dyadic m A.Concat intE listE

    -- Miscellaneous expressions
    , testOK   150 $ A.MostPos m A.Int
    , testFail 151 $ A.MostPos m twoIntsT
    , testOK   152 $ A.MostNeg m A.Int
    , testFail 153 $ A.MostNeg m twoIntsT
    , testOK   154 $ A.SizeType m twoIntsT
    , testFail 155 $ A.SizeType m A.Int
    , testOK   156 $ A.SizeExpr m twoIntsE
    , testFail 157 $ A.SizeExpr m intE
    , testOK   158 $ A.SizeExpr m twoTwoIntsE
    , testOK   159 $ A.SizeExpr m (sub0E twoTwoIntsE)
    , testFail 160 $ A.SizeExpr m (sub0E (sub0E twoTwoIntsE))
    , testFail 161 $ A.SizeExpr m (sub0E intE)
    , testOK   162 $ A.SizeVariable m intsV
    , testFail 163 $ A.SizeVariable m byteV
    , testOK   164 $ A.ExprVariable m intV
    , testOK   165 $ intE
    , testOK   166 $ boolLiteral True
    , testOK   167 $ A.IntrinsicFunctionCall m "SQRT" [realE]
    , testFail 168 $ A.IntrinsicFunctionCall m "SQRT" [intE]
    , testFail 169 $ A.IntrinsicFunctionCall m "SQRT" [realE, intE]
    , testOK   170 $ subxE coord2E
    , testFail 171 $ subxE twoTwoIntsE
    , testFail 172 $ subxE intE
    , testFail 173 $ A.SubscriptedExpr m (A.SubscriptField m function0) coord2E
    , testOK   174 $ A.OffsetOf m coord2T (simpleName "x")
    , testFail 175 $ A.OffsetOf m coord2T function0
    , testFail 176 $ A.OffsetOf m A.Int (simpleName "x")

    -- Conversions
    , testOK   200 $ A.Conversion m A.Round A.Int realE
    , testOK   201 $ A.Conversion m A.Round A.Real32 intE
    , testFail 202 $ A.Conversion m A.Round A.Real32 twoIntsE
    , testFail 203 $ A.Conversion m A.Round twoIntsT realE

    -- Function calls
    , testOK   220 $ A.FunctionCall m function0 []
    , testOK   221 $ A.FunctionCall m function1 [intE]
    , testOK   222 $ A.FunctionCall m function2 [intE, intE]
    , testFail 223 $ A.FunctionCall m function22 [intE, intE]
    , testFail 224 $ A.FunctionCall m function0 [intE]
    , testFail 225 $ A.FunctionCall m function1 [intE, intE]
    , testFail 226 $ A.FunctionCall m function2 [intE]
    , testFail 227 $ A.FunctionCall m function2 [intE, intE, intE]
    , testFail 228 $ A.FunctionCall m (simpleName "someInt") [intE]
    , testFail 229 $ A.FunctionCall m function1 [realE]
    , testFail 230 $ A.FunctionCall m function2 [intE, realE]
    , testFail 231 $ A.FunctionCall m function2 [twoIntsE, intE]
    , testOK   232 $ A.FunctionCall m function1 [sub0E twoIntsE]

    -- Mobile allocations
    , testOK   250 $ A.AllocMobile m (A.Mobile A.Int) (Just intE)
    , testOK   251 $ A.AllocMobile m (A.Mobile A.Int) Nothing
    , testFail 252 $ A.AllocMobile m (A.Mobile A.Int) (Just realE)
    , testFail 253 $ A.AllocMobile m (A.Mobile A.Int) (Just realE)
    , testOK   254 $ A.AllocMobile m (A.Mobile A.Real32) (Just realE)
    , testOK   254 $ A.AllocMobile m (A.Mobile twoIntsT) (Just twoIntsE)
    , testFail 255 $ A.AllocMobile m (A.Mobile unknownIntsT) (Just twoIntsE)
    , testFail 256 $ A.AllocMobile m (A.Mobile unknownIntsT) Nothing

    --}}}
    --{{{  processes

    -- Inputs
    , testOK   1000 $ inputSimple countedIntsC [A.InCounted m intV intsV]
    , testFail 1001 $ inputSimple countedIntsC [A.InCounted m realV intsV]
    , testFail 1002 $ inputSimple countedIntsC [A.InCounted m intV intV]
    , testFail 1003 $ inputSimple countedIntsC [A.InCounted m constIntV intsV]
    , testFail 1004 $ inputSimple countedIntsC [A.InCounted m intV constIntsV]
    , testFail 1005 $ inputSimple countedIntsC [A.InCounted m intV intsC]
    , testOK   1010 $ inputSimple intC [inv intV]
    , testFail 1011 $ inputSimple intC [inv constIntV]
    , testFail 1012 $ inputSimple intC [inv intC]
    , testFail 1013 $ inputSimple intV [inv intV]
    , testFail 1014 $ inputSimple intV []
    , testFail 1015 $ inputSimple intV [inv intV, inv intV]
    , testFail 1016 $ inputSimple tim [inv intV]
    , testOK   1020 $ inputSimple iirC [inv intV, inv intV, inv realV]
    , testFail 1021 $ inputSimple iirC [inv intV, inv realV, inv intV]
    , testFail 1022 $ inputSimple iirC [inv realV, inv intV, inv intV]
    , testFail 1023 $ inputSimple iirC [inv intV, inv intV]
    , testFail 1024 $ inputSimple iirC [inv intV, inv intV, inv realV, inv intV]
    , testOK   1030 $ inputCase caseC [ vari "one" [inv intV]
                                      , vari "two" [inv realV]
                                      , vari "three" []
                                      ]
    , testFail 1031 $ inputCase caseC [ vari "one" [inv realV]
                                      , vari "two" [inv realV]
                                      , vari "three" []
                                      ]
    , testFail 1032 $ inputCase caseC [ vari "one" [inv intV]
                                      , vari "two" [inv intV]
                                      , vari "three" []
                                      ]
    , testFail 1033 $ inputCase caseC [ vari "one" [inv intV]
                                      , vari "herring" [inv realV]
                                      , vari "three" []
                                      ]
    , testFail 1034 $ inputCase caseC [ vari "one" [inv intV, inv realV]
                                      , vari "two" [inv realV]
                                      , vari "three" []
                                      ]
    , testFail 1035 $ inputCase caseC [ vari "one" []
                                      , vari "two" []
                                      , vari "three" []
                                      ]

    -- Outputs
    , testOK   1100 $ outputSimple countedIntsC [A.OutCounted m intE twoIntsE]
    , testFail 1101 $ outputSimple countedIntsC [A.OutCounted m realE twoIntsE]
    , testFail 1102 $ outputSimple countedIntsC [A.OutCounted m intE intE]
    , testOK   1110 $ outputSimple intC [oute intE]
    , testFail 1111 $ outputSimple intC [oute intCE]
    , testFail 1112 $ outputSimple intV [oute intE]
    , testFail 1113 $ outputSimple tim [oute intE]
    , testOK   1120 $ outputSimple iirC [oute intE, oute intE, oute realE]
    , testFail 1121 $ outputSimple iirC [oute intE, oute realE, oute intE]
    , testFail 1122 $ outputSimple iirC [oute realE, oute intE, oute intE]
    , testFail 1123 $ outputSimple iirC [oute intE, oute intE]
    , testFail 1124 $ outputSimple iirC [oute intE, oute intE, oute realE,
                                         oute intE]
    , testOK   1130 $ outputCase caseC "one" [oute intE]
    , testOK   1131 $ outputCase caseC "two" [oute realE]
    , testOK   1132 $ outputCase caseC "three" []
    , testFail 1133 $ outputCase caseC "three" [oute intE]
    , testFail 1134 $ outputCase caseC "two" [oute realE, oute intE]
    , testFail 1135 $ outputCase caseC "two" []
    , testFail 1136 $ outputCase caseC "two" [oute intE]
    , testFail 1137 $ outputCase caseC "herring" [oute intE]

    -- Timer operations
    , testOK   1180 $ A.Input m tim $ A.InputTimerRead m $ inv intV
    , testOK   1181 $ A.Input m tim $ A.InputTimerAfter m intE
    , testOK   1182 $ A.Input m tim $ A.InputTimerFor m intE
    , testFail 1183 $ A.Input m tim $ A.InputTimerRead m $ inv realV
    , testFail 1184 $ A.Input m caseC $ A.InputTimerRead m $ inv intV
    , testFail 1185 $ A.Input m tim $ A.InputTimerAfter m realE
    , testFail 1186 $ A.Input m tim $ A.InputTimerFor m realE

    -- Replicators
    , testOK   1200 $ testRep i $ A.For m intE intE
    , testFail 1201 $ testRep i $ A.For m realE intE
    , testFail 1202 $ testRep i $ A.For m intE realE
    , testOK   1203 $ testRep i $ A.ForEach m twoIntsE
    , testOK   1204 $ testRep i $ A.ForEach m listE
    , testFail 1205 $ testRep i $ A.ForEach m intE

    -- Choices
    , testOK   1300 $ testChoice $ A.Choice m boolE skip
    , testFail 1301 $ testChoice $ A.Choice m intE skip

    -- Options
    , testOK   1320 $ testOption intE $ A.Option m [] skip
    , testOK   1321 $ testOption intE $ A.Option m [intE] skip
    , testOK   1322 $ testOption intE $ A.Option m [intE, intE] skip
    , testFail 1323 $ testOption realE $ A.Option m [realE] skip
    , testFail 1324 $ testOption twoIntsE $ A.Option m [twoIntsE] skip
    , testOK   1325 $ testOption boolE $ A.Option m [boolE] skip
    , testFail 1326 $ testOption boolE $ A.Option m [intE] skip
    , testFail 1327 $ testOption boolE $ A.Option m [boolE, intE] skip

    -- Assignment
    , testOK   1400 $ A.Assign m [intV] $ A.ExpressionList m [intE]
    , testOK   1401 $ A.Assign m [intV, intV] $ A.ExpressionList m [intE, intE]
    , testFail 1402 $ A.Assign m [intV] $ A.ExpressionList m [realE]
    , testFail 1403 $ A.Assign m [intV, intV] $ A.ExpressionList m [intE]
    , testFail 1404 $ A.Assign m [intV] $ A.ExpressionList m [intE, intE]
    , testOK   1410 $ A.Assign m [intV, intV]
                               $ A.FunctionCallList m function22 [intE, intE]
    , testFail 1411 $ A.Assign m [intV]
                               $ A.FunctionCallList m function22 [intE, intE]
    , testFail 1412 $ A.Assign m [intV, intV, intV]
                               $ A.FunctionCallList m function22 [intE, intE]
    , testFail 1413 $ A.Assign m [intV, realV]
                               $ A.FunctionCallList m function22 [intE, intE]
    , testFail 1414 $ A.Assign m [intV, realV]
                               $ A.FunctionCallList m function22 [intE, realE]
    , testFail 1415 $ A.Assign m [intV, realV]
                               $ A.FunctionCallList m function22 [realE]

    -- Alt
    , testOK   1500 $ testAlt $ A.Alternative m true intC (insim [inv intV]) skip
    , testOK   1501 $ testAlt $ A.Alternative m true tim
                                              (A.InputTimerAfter m intE) skip
    , testOK   1502 $ testAlt $ A.Alternative m boolE intC
                                                  (insim [inv intV]) skip
    , testOK   1503 $ testAlt $ A.AlternativeSkip m boolE skip
    , testFail 1504 $ testAlt $ A.Alternative m true intC (insim [inv realV]) skip
    , testFail 1505 $ testAlt $ A.Alternative m true tim
                                              (A.InputTimerRead m $ inv intV)
                                              skip
    , testFail 1506 $ testAlt $ A.Alternative m intE intC
                                                  (insim [inv intV]) skip
    , testFail 1507 $ testAlt $ A.AlternativeSkip m intE skip

    -- Proc calls
    , testOK   1600 $ proccall "proc0" []
    , testOK   1601 $ proccall "proc1" [A.ActualExpression intE]
    , testOK   1602 $ proccall "proc2" [A.ActualExpression intE,
                                        A.ActualVariable intV]
    , testFail 1603 $ proccall "proc0" [A.ActualExpression intE]
    , testFail 1604 $ proccall "proc1" [A.ActualExpression realE]
    , testFail 1605 $ proccall "proc1" [A.ActualExpression intE,
                                        A.ActualExpression intE]
    , testFail 1606 $ proccall "herring" []

    -- Miscellaneous processes
    , testOK   1900 $ A.ClearMobile m mobileIntV
    , testFail 1901 $ A.ClearMobile m intV
    , testOK   1902 $ A.Skip m
    , testOK   1903 $ A.Stop m
    , testOK   1904 $ A.While m boolE skip
    , testFail 1905 $ A.While m intE skip
    , testOK   1906 $ A.Par m A.PlainPar sskip
    , testOK   1907 $ A.Processor m intE skip
    , testFail 1908 $ A.Processor m realE skip
    , testOK   1909 $ A.IntrinsicProcCall m "RESCHEDULE" []
    , testOK   1910 $ A.IntrinsicProcCall m "ASSERT"
                                          [A.ActualExpression boolE]
    , testFail 1911 $ A.IntrinsicProcCall m "ASSERT"
                                          [A.ActualExpression intE]
    , testFail 1912 $ A.IntrinsicProcCall m "ASSERT" []
    , testFail 1913 $ A.IntrinsicProcCall m "RESCHEDULE"
                                          [A.ActualExpression boolE]
    , testFail 1914 $ A.IntrinsicProcCall m "HERRING" []

    --}}}
    --{{{  specifications

    -- Place
    , testOK   2000 $ A.Place m intE
    , testFail 2001 $ A.Place m twoIntsE

    -- Declaration
    , testOK   2010 $ A.Declaration m A.Int
    , testOK   2011 $ A.Declaration m twoIntsT

    -- Is
    , testOK   2020 $ A.Is m A.Abbrev A.Int intV
    , testFail 2021 $ A.Is m A.ValAbbrev A.Int intV
    , testFail 2022 $ A.Is m A.Original A.Int intV
    , testFail 2023 $ A.Is m A.Abbrev A.Real32 intV
    , testOK   2024 $ A.Is m A.Abbrev chanIntT intC
    , testFail 2025 $ A.Is m A.ValAbbrev chanIntT intC
    , testOK   2026 $ A.Is m A.Abbrev (A.Timer A.OccamTimer) tim
    , testFail 2027 $ A.Is m A.ValAbbrev (A.Timer A.OccamTimer) tim

    -- IsExpr
    , testOK   2030 $ A.IsExpr m A.ValAbbrev A.Int intE
    , testFail 2031 $ A.IsExpr m A.Abbrev A.Int intE
    , testFail 2032 $ A.IsExpr m A.Original A.Int intE
    , testFail 2033 $ A.IsExpr m A.ValAbbrev A.Real32 intE

    -- IsChannelArray
    , testOK   2040 $ A.IsChannelArray m chansIntT [intC, intC]
    , testOK   2041 $ A.IsChannelArray m uchansIntT [intC, intC]
    , testOK   2042 $ A.IsChannelArray m uchansIntT []
    , testFail 2043 $ A.IsChannelArray m chansIntT [intC]
    , testFail 2044 $ A.IsChannelArray m chansIntT [iirC, intC]
    , testFail 2045 $ A.IsChannelArray m chansIntT [intC, intC, intC]
    , testFail 2046 $ A.IsChannelArray m chansIntT [intV, intV]

    -- DataType
    , testOK   2050 $ A.DataType m A.Int
    , testOK   2051 $ A.DataType m twoIntsT
    , testOK   2052 $ A.DataType m myTwoIntsT
    , testFail 2053 $ A.DataType m chanIntT
    , testFail 2054 $ A.DataType m $ A.Timer A.OccamTimer

    -- RecordType
    , testOK   2060 $ A.RecordType m True []
    , testOK   2061 $ A.RecordType m False []
    , testOK   2062 $ A.RecordType m False [ (simpleName "x", A.Int)
                                           , (simpleName "y", A.Int)
                                           , (simpleName "z", A.Int)
                                           ]
    , testFail 2063 $ A.RecordType m False [(simpleName "c", chanIntT)]
    , testOK   2064 $ A.RecordType m False [(simpleName "c", A.Mobile A.Int)]
    , testFail 2065 $ A.RecordType m False [ (simpleName "x", A.Int)
                                           , (simpleName "x", A.Real32)
                                           ]

    -- Protocol
    , testOK   2070 $ A.Protocol m [A.Int]
    , testOK   2071 $ A.Protocol m [A.Int, A.Real32, twoIntsT]
    , testOK   2072 $ A.Protocol m [A.Mobile A.Int]
    , testFail 2073 $ A.Protocol m []
    , testFail 2074 $ A.Protocol m [chanIntT]
    , testOK   2075 $ A.Protocol m [A.Counted A.Int unknownIntsT]
    , testFail 2076 $ A.Protocol m [A.Counted A.Real32 unknownIntsT]
    , testFail 2077 $ A.Protocol m [A.Counted A.Int A.Int]
    , testFail 2078 $ A.Protocol m [A.Counted A.Int twoIntsT]

    , testOK   2080 $ A.ProtocolCase m [ (simpleName "one", [A.Int])
                                       , (simpleName "two", [A.Real32])
                                       , (simpleName "three", [])
                                       ]
    , testFail 2081 $ A.ProtocolCase m [ (simpleName "one", [A.Int])
                                       , (simpleName "one", [A.Real32])
                                       ]

    -- Proc
    , testOK   2090 $ A.Proc m A.PlainSpec [] skip
    , testOK   2091 $ A.Proc m A.InlineSpec [] skip
    , testOK   2092 $ A.Proc m A.PlainSpec
                             [ A.Formal A.Abbrev A.Int (simpleName "x")
                             , A.Formal A.ValAbbrev A.Int (simpleName "y")
                             , A.Formal A.Abbrev chanIntT (simpleName "c")
                             ]
                             skip
    , testFail 2093 $ A.Proc m A.PlainSpec
                             [ A.Formal A.Original A.Int (simpleName "x")
                             ]
                             skip

    -- Function
    , testOK   2100 $ A.Function m A.PlainSpec [A.Int] [] returnOne
    , testOK   2110 $ A.Function m A.InlineSpec [A.Int] [] returnOne
    , testFail 2120 $ A.Function m A.PlainSpec [] [] returnNone
    , testOK   2130 $ A.Function m A.PlainSpec [A.Int]
                                 [ A.Formal A.ValAbbrev A.Int (simpleName "x")
                                 , A.Formal A.ValAbbrev A.Bool (simpleName "b")
                                 , A.Formal A.ValAbbrev A.Int (simpleName "q")
                                 ]
                                 returnOne
    , testFail 2140 $ A.Function m A.PlainSpec [A.Int]
                                 [A.Formal A.Abbrev A.Int (simpleName "x")]
                                 returnOne
    , testFail 2150 $ A.Function m A.PlainSpec [A.Int]
                        [A.Formal A.ValAbbrev chanIntT (simpleName "c")]
                        returnOne
    , testFail 2160 $ A.Function m A.PlainSpec [A.Int] [] returnNone
    , testFail 2170 $ A.Function m A.PlainSpec [A.Int] [] returnTwo

    --}}}
    --{{{  retyping

    -- Definitely OK at compile time
    , testOK   3000 $ retypesV A.Int intV
    , testOK   3001 $ retypesE A.Int intE
    , testOK   3002 $ retypesV A.Byte byteV
    , testOK   3003 $ retypesE A.Byte byteE
    , testOK   3004 $ retypesV known1 intV
    , testOK   3005 $ retypesV known2 intV
    , testOK   3006 $ retypesV both intV
    , testOK   3007 $ retypesV unknown1 intV

    -- Definitely wrong at compile time
    , testFail 3100 $ retypesV A.Byte intV
    , testFail 3101 $ retypesV A.Int byteV
    , testFail 3102 $ retypesV unknown2 intV
    , testFail 3103 $ retypesV unknown2 intsV
    , testFail 3104 $ retypesV A.Byte intsV

    -- Can't tell; need a runtime check
    , testOK   3200 $ retypesV unknown1 intsV
    , testOK   3201 $ retypesV A.Int intsV
    , testOK   3202 $ retypesV known2 intsV
    , testOK   3203 $ retypesV unknown1 bytesV

    --}}}
    ]
  where
    testOK :: (Show a, Data a) => Int -> a -> Test
    testOK n orig
        = TestCase $ testPass ("testOccamTypes" ++ show n)
                              orig OccamTypes.checkTypes orig
                              startState

    testFail :: (Show a, Data a) => Int -> a -> Test
    testFail n orig
        = TestCase $ testPassShouldFail ("testOccamTypes" ++ show n)
                                        OccamTypes.checkTypes orig
                                        startState

    --{{{  expression fragments

    true = A.True emptyMeta
    subex sub = A.SubscriptedExpr m sub twoIntsE
    intV = variable "varInt"
    intE = intLiteral 42
    realV = variable "varReal"
    realE = A.Literal m A.Real32 $ A.RealLiteral m "3.14159"
    byteV = variable "varByte"
    byteE = byteLiteral 42
    intsV = variable "varInts"
    bytesV = variable "varBytes"
    constIntV = variable "constInt"
    constIntsV = variable "constInts"
    boolE = boolLiteral True
    unknownIntsT = A.Array [A.UnknownDimension] A.Int
    twoIntsT = A.Array [dimension 2] A.Int
    twoTwoIntsT = A.Array [dimension 2, dimension 2] A.Int
    twoBytesT = A.Array [dimension 2] A.Byte
    threeIntsT = A.Array [dimension 3] A.Int
    ae = A.ArrayElemExpr intE
    twoInts = A.ArrayLiteral m [ae, ae]
    twoIntsE = A.Literal m twoIntsT twoInts
    twoTwoInts = A.ArrayLiteral m [A.ArrayElemArray [ae, ae],
                                   A.ArrayElemArray [ae, ae]]
    twoTwoIntsE = A.Literal m twoTwoIntsT twoTwoInts
    myIntT = A.UserDataType (simpleName "MYINT")
    myTwoIntsT = A.UserDataType (simpleName "MY2INT")
    coord2T = A.Record (simpleName "COORD2")
    coord2 = A.RecordLiteral m [intE, intE]
    coord2E = A.Literal m coord2T coord2
    coord3T = A.Record (simpleName "COORD3")
    coord3 = A.RecordLiteral m [realE, realE, realE]
    chanT t = A.Chan A.DirUnknown (A.ChanAttributes False False) t
    chanIntT = chanT A.Int
    chansIntT = A.Array [dimension 2] $ chanT A.Int
    uchansIntT = A.Array [A.UnknownDimension] $ chanT A.Int
    intC = variable "chanInt"
    intCE = A.ExprVariable m intC
    intsC = variable "chansInt"
    mobileIntV = variable "mobileInt"
    sub0 = A.Subscript m A.NoCheck (intLiteral 0)
    sub0E = A.SubscriptedExpr m sub0
    subx = A.SubscriptField m (simpleName "x")
    subxE = A.SubscriptedExpr m subx
    function0 = simpleName "function0"
    function1 = simpleName "function1"
    function2 = simpleName "function2"
    function22 = simpleName "function22"
    listT = A.List A.Int
    listE = A.Literal m listT (A.ListLiteral m [intE, intE, intE])
    i = simpleName "i"
    countedIntsC = variable "chanCountedInts"
    iirC = variable "chanIIR"
    caseC = variable "chanCaseProto"

    --}}}
    --{{{  process fragments

    skip = A.Skip m
    sskip = A.Only m skip
    insim iis = A.InputSimple m iis
    inputSimple c iis = A.Input m c $ insim iis
    inputCase c vs = A.Input m c
                             $ A.InputCase m (A.Several m (map (A.Only m) vs))
    vari tag iis = A.Variant m (simpleName tag) iis skip
    outputSimple c ois = A.Output m c ois
    outputCase c tag ois = A.OutputCase m c (simpleName tag) ois
    testRep n r = A.Seq m $ A.Spec m (A.Specification m n (A.Rep m r)) sskip
    testChoice c = A.If m $ A.Only m c
    testOption e o = A.Case m e $ A.Only m o
    inv = A.InVariable m
    oute = A.OutExpression m
    tim = variable "tim"
    testAlt a = A.Alt m True $ A.Only m a
    proccall n = A.ProcCall m (simpleName n)

    --}}}
    --{{{  specification fragments

    returnNone = Left $ A.Only m $ A.ExpressionList m []
    returnOne = Left $ A.Only m $ A.ExpressionList m [intE]
    returnTwo = Left $ A.Only m $ A.ExpressionList m [intE, intE]

    retypesV = A.Retypes m A.Abbrev
    retypesE = A.RetypesExpr m A.ValAbbrev
    known1 = A.Array [dimension 4] A.Byte
    known2 = A.Array [dimension 2, dimension 2] A.Byte
    both = A.Array [dimension 2, A.UnknownDimension] A.Byte
    unknown1 = A.Array [A.UnknownDimension] A.Int
    unknown2 = A.Array [A.UnknownDimension, A.UnknownDimension] A.Int

    --}}}

ioTests :: IO Test
ioTests = liftM (TestLabel "OccamTypesTest" . TestList) $ sequence $
    map return
        [ testOccamTypes
        ]
    ++ map (automaticTest FrontendOccam)
        [ "testcases/automatic/initial-result-1.occ.test"
        , "testcases/automatic/initial-result-2.occ.test"
        ]
