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

-- | Generate C code from the mangled AST.
module GenerateC where

import Data.Char
import Data.Generics
import Data.List
import Data.Maybe
import qualified Data.Set as Set
import Control.Monad.Writer
import Control.Monad.Error
import Control.Monad.State
import Numeric
import Text.Printf

import qualified AST as A
import CompState
import EvalConstants
import EvalLiterals
import Metadata
import Pass
import Errors
import TLP
import Types
import Utils

--{{{  passes related to C generation
genCPasses :: [(String, Pass)]
genCPasses =
  [ ("Identify parallel processes", identifyParProcs)
  ]

-- | Identify processes that we'll need to compute the stack size of.
identifyParProcs :: Pass
identifyParProcs = everywhereM (mkM doProcess)
  where
    doProcess :: A.Process -> PassM A.Process
    doProcess p@(A.Par _ _ s) = findProcs s >> return p
    doProcess p = return p

    findProcs :: A.Structured -> PassM ()
    findProcs (A.Rep _ _ s) = findProcs s
    findProcs (A.Spec _ _ s) = findProcs s
    findProcs (A.ProcThen _ _ s) = findProcs s
    findProcs (A.Several _ ss) = sequence_ $ map findProcs ss
    findProcs (A.OnlyP _ (A.ProcCall _ n _))
        = modify (\cs -> cs { csParProcs = Set.insert n (csParProcs cs) })
--}}}

--{{{  monad definition
type CGen = WriterT [String] PassM

instance Die CGen where
  die = throwError
--}}}

--{{{  generator ops
-- | Operations for turning various things into C.
-- These are in a structure so that we can reuse operations in other
-- backends without breaking the mutual recursion.
data GenOps = GenOps {
    declareArraySizes :: GenOps -> [A.Dimension] -> A.Name -> CGen (),
    declareFree :: GenOps -> Meta -> A.Type -> A.Variable -> Maybe (CGen ()),
    declareInit :: GenOps -> Meta -> A.Type -> A.Variable -> Maybe (CGen ()),
    declareType :: GenOps -> A.Type -> CGen (),
    genActual :: GenOps -> A.Actual -> CGen (),
    genActuals :: GenOps -> [A.Actual] -> CGen (),
    genAlt :: GenOps -> Bool -> A.Structured -> CGen (),
    genArrayAbbrev :: GenOps -> A.Variable -> (CGen (), A.Name -> CGen ()),
    genArrayLiteralElems :: GenOps -> [A.ArrayElem] -> CGen (),
    genArraySize :: GenOps -> Bool -> CGen () -> A.Name -> CGen (),
    genArraySizesLiteral :: GenOps -> [A.Dimension] -> CGen (),
    genArraySizesSize :: GenOps -> [A.Dimension] -> CGen (),
    genArraySubscript :: GenOps -> Bool -> A.Variable -> [A.Expression] -> CGen (),
    genAssert :: GenOps -> Meta -> A.Expression -> CGen (),
    genAssign :: GenOps -> Meta -> [A.Variable] -> A.ExpressionList -> CGen (),
    genBytesIn :: GenOps -> A.Type -> Maybe A.Variable -> CGen (),
    genBytesIn' :: GenOps -> A.Type -> Maybe A.Variable -> CGen (Maybe Int),
    genCase :: GenOps -> Meta -> A.Expression -> A.Structured -> CGen (),
    genCheckedConversion :: GenOps -> Meta -> A.Type -> A.Type -> CGen () -> CGen (),
    genConversion :: GenOps -> Meta -> A.ConversionMode -> A.Type -> A.Expression -> CGen (),
    genConversionSymbol :: GenOps -> A.Type -> A.Type -> A.ConversionMode -> CGen (),
    genDecl :: GenOps -> A.AbbrevMode -> A.Type -> A.Name -> CGen (),
    genDeclType :: GenOps -> A.AbbrevMode -> A.Type -> CGen (),
    genDeclaration :: GenOps -> A.Type -> A.Name -> CGen (),
    genDyadic :: GenOps -> Meta -> A.DyadicOp -> A.Expression -> A.Expression -> CGen (),
    genExpression :: GenOps -> A.Expression -> CGen (),
    genFlatArraySize :: GenOps -> [A.Dimension] -> CGen (),
    genFormal :: GenOps -> A.Formal -> CGen (),
    genFormals :: GenOps -> [A.Formal] -> CGen (),
    genFuncDyadic :: GenOps -> Meta -> String -> A.Expression -> A.Expression -> CGen (),
    genFuncMonadic :: GenOps -> Meta -> String -> A.Expression -> CGen (),
    genIf :: GenOps -> Meta -> A.Structured -> CGen (),
    genInput :: GenOps -> A.Variable -> A.InputMode -> CGen (),
    genInputCase :: GenOps -> Meta -> A.Variable -> A.Structured -> CGen (),
    genInputItem :: GenOps -> A.Variable -> A.InputItem -> CGen (),
    genIntrinsicFunction :: GenOps -> Meta -> String -> [A.Expression] -> CGen (),
    genIntrinsicProc :: GenOps -> Meta -> String -> [A.Actual] -> CGen (),
    genLiteral :: GenOps -> A.LiteralRepr -> CGen (),
    genLiteralRepr :: GenOps -> A.LiteralRepr -> CGen (),
    genMissing :: GenOps -> String -> CGen (),
    genMonadic :: GenOps -> Meta -> A.MonadicOp -> A.Expression -> CGen (),
    genOutput :: GenOps -> A.Variable -> [A.OutputItem] -> CGen (),
    genOutputCase :: GenOps -> A.Variable -> A.Name -> [A.OutputItem] -> CGen (),
    genOutputItem :: GenOps -> A.Variable -> A.OutputItem -> CGen (),
    genOverArray :: GenOps -> Meta -> A.Variable -> (SubscripterFunction -> Maybe (CGen ())) -> CGen (),
    genPar :: GenOps -> A.ParMode -> A.Structured -> CGen (),
    genProcCall :: GenOps -> A.Name -> [A.Actual] -> CGen (),
    genProcess :: GenOps -> A.Process -> CGen (),
    genReplicator :: GenOps -> A.Replicator -> CGen () -> CGen (),
    genReplicatorLoop :: GenOps -> A.Replicator -> CGen (),
    genReplicatorSize :: GenOps -> A.Replicator -> CGen (),
    genRetypeSizes :: GenOps -> Meta -> A.AbbrevMode -> A.Type -> A.Name -> A.Type -> A.Variable -> CGen (),
    genSeq :: GenOps -> A.Structured -> CGen (),
    genSimpleDyadic :: GenOps -> String -> A.Expression -> A.Expression -> CGen (),
    genSimpleMonadic :: GenOps -> String -> A.Expression -> CGen (),
    genSizeSuffix :: GenOps -> String -> CGen (),
    genSlice :: GenOps -> A.Variable -> A.Variable -> A.Expression -> A.Expression -> [A.Dimension] -> (CGen (), A.Name -> CGen ()),
    genSpec :: GenOps -> A.Specification -> CGen () -> CGen (),
    genSpecMode :: GenOps -> A.SpecMode -> CGen (),
    genStop :: GenOps -> Meta -> String -> CGen (),
    genStructured :: GenOps -> A.Structured -> (A.Structured -> CGen ()) -> CGen (),
    genTLPChannel :: GenOps -> TLPChannel -> CGen (),
    genTimerRead :: GenOps -> A.Variable -> A.Variable -> CGen (),
    genTimerWait :: GenOps -> A.Expression -> CGen (),
    genTopLevel :: GenOps -> A.Process -> CGen (),
    genType :: GenOps -> A.Type -> CGen (),
    genTypeSymbol :: GenOps -> String -> A.Type -> CGen (),
    genUnfoldedExpression :: GenOps -> A.Expression -> CGen (),
    genUnfoldedVariable :: GenOps -> Meta -> A.Variable -> CGen (),
    genVariable :: GenOps -> A.Variable -> CGen (),
    genVariable' :: GenOps -> Bool -> A.Variable -> CGen (),
    genVariableAM :: GenOps -> A.Variable -> A.AbbrevMode -> CGen (),
    genVariableUnchecked :: GenOps -> A.Variable -> CGen (),
    genWhile :: GenOps -> A.Expression -> A.Process -> CGen (),
    getScalarType :: GenOps -> A.Type -> Maybe String,
    introduceSpec :: GenOps -> A.Specification -> CGen (),
    removeSpec :: GenOps -> A.Specification -> CGen ()
  }

-- | Call an operation in GenOps.
call :: (GenOps -> GenOps -> t) -> GenOps -> t
call f ops = f ops ops

-- | Operations for the C backend.
cgenOps :: GenOps
cgenOps = GenOps {
    declareArraySizes = cdeclareArraySizes,
    declareFree = cdeclareFree,
    declareInit = cdeclareInit,
    declareType = cdeclareType,
    genActual = cgenActual,
    genActuals = cgenActuals,
    genAlt = cgenAlt,
    genArrayAbbrev = cgenArrayAbbrev,
    genArrayLiteralElems = cgenArrayLiteralElems,
    genArraySize = cgenArraySize,
    genArraySizesLiteral = cgenArraySizesLiteral,
    genArraySizesSize = cgenArraySizesSize,
    genArraySubscript = cgenArraySubscript,
    genAssert = cgenAssert,
    genAssign = cgenAssign,
    genBytesIn = cgenBytesIn,
    genBytesIn' = cgenBytesIn',
    genCase = cgenCase,
    genCheckedConversion = cgenCheckedConversion,
    genConversion = cgenConversion,
    genConversionSymbol = cgenConversionSymbol,
    genDecl = cgenDecl,
    genDeclType = cgenDeclType,
    genDeclaration = cgenDeclaration,
    genDyadic = cgenDyadic,
    genExpression = cgenExpression,
    genFlatArraySize = cgenFlatArraySize,
    genFormal = cgenFormal,
    genFormals = cgenFormals,
    genFuncDyadic = cgenFuncDyadic,
    genFuncMonadic = cgenFuncMonadic,
    genIf = cgenIf,
    genInput = cgenInput,
    genInputCase = cgenInputCase,
    genInputItem = cgenInputItem,
    genIntrinsicFunction = cgenIntrinsicFunction,
    genIntrinsicProc = cgenIntrinsicProc,
    genLiteral = cgenLiteral,
    genLiteralRepr = cgenLiteralRepr,
    genMissing = cgenMissing,
    genMonadic = cgenMonadic,
    genOutput = cgenOutput,
    genOutputCase = cgenOutputCase,
    genOutputItem = cgenOutputItem,
    genOverArray = cgenOverArray,
    genPar = cgenPar,
    genProcCall = cgenProcCall,
    genProcess = cgenProcess,
    genReplicator = cgenReplicator,
    genReplicatorLoop = cgenReplicatorLoop,
    genReplicatorSize = cgenReplicatorSize,
    genRetypeSizes = cgenRetypeSizes,
    genSeq = cgenSeq,
    genSimpleDyadic = cgenSimpleDyadic,
    genSimpleMonadic = cgenSimpleMonadic,
    genSizeSuffix = cgenSizeSuffix,
    genSlice = cgenSlice,
    genSpec = cgenSpec,
    genSpecMode = cgenSpecMode,
    genStop = cgenStop,
    genStructured = cgenStructured,
    genTLPChannel = cgenTLPChannel,
    genTimerRead = cgenTimerRead,
    genTimerWait = cgenTimerWait,
    genTopLevel = cgenTopLevel,
    genType = cgenType,
    genTypeSymbol = cgenTypeSymbol,
    genUnfoldedExpression = cgenUnfoldedExpression,
    genUnfoldedVariable = cgenUnfoldedVariable,
    genVariable = cgenVariable,
    genVariable' = cgenVariable',
    genVariableAM = cgenVariableAM,
    genVariableUnchecked = cgenVariableUnchecked,
    genWhile = cgenWhile,
    getScalarType = cgetScalarType,
    introduceSpec = cintroduceSpec,
    removeSpec = cremoveSpec
  }
--}}}

--{{{  top-level
generate :: GenOps -> A.Process -> PassM String
generate ops ast
    =  do (a, out) <- runWriterT (call genTopLevel ops ast)
          return $ concat out

generateC :: A.Process -> PassM String
generateC = generate cgenOps

cgenTLPChannel :: GenOps -> TLPChannel -> CGen ()
cgenTLPChannel _ TLPIn = tell ["in"]
cgenTLPChannel _ TLPOut = tell ["out"]
cgenTLPChannel _ TLPError = tell ["err"]

cgenTopLevel :: GenOps -> A.Process -> CGen ()
cgenTopLevel ops p
    =  do tell ["#include <tock_support.h>\n"]
          cs <- get
          tell ["extern int " ++ nameString n ++ "_stack_size;\n"
                | n <- Set.toList $ csParProcs cs]
          call genProcess ops p
          (name, chans) <- tlpInterface
          tell ["void tock_main (Process *me, Channel *in, Channel *out, Channel *err) {\n"]
          genName name
          tell [" (me"]
          sequence_ [tell [", "] >> call genTLPChannel ops c | (_,c) <- chans]
          tell [");\n"]
          tell ["}\n"]
--}}}

--{{{  utilities
cgenMissing :: GenOps -> String -> CGen ()
cgenMissing _ s = tell ["\n#error Unimplemented: ", s, "\n"]

--{{{  simple punctuation
genComma :: CGen ()
genComma = tell [", "]

seqComma :: [CGen ()] -> CGen ()
seqComma ps = sequence_ $ intersperse genComma ps

genLeftB :: CGen ()
genLeftB = tell ["{ "]

genRightB :: CGen ()
genRightB = tell [" }"]
--}}}

-- | A function that applies a subscript to a variable.
type SubscripterFunction = A.Variable -> A.Variable

-- | Map an operation over every item of an occam array.
cgenOverArray :: GenOps -> Meta -> A.Variable -> (SubscripterFunction -> Maybe (CGen ())) -> CGen ()
cgenOverArray ops m var func
    =  do A.Array ds _ <- typeOfVariable var
          specs <- sequence [makeNonceVariable "i" m A.Int A.VariableName A.Original | _ <- ds]
          let indices = [A.Variable m n | A.Specification _ n _ <- specs]

          let arg = (\var -> foldl (\v s -> A.SubscriptedVariable m s v) var [A.Subscript m $ A.ExprVariable m i | i <- indices])
          case func arg of
            Just p ->
              do sequence_ [do tell ["for (int "]
                               call genVariable ops i
                               tell [" = 0; "]
                               call genVariable ops i
                               tell [" < "]
                               call genVariable ops var
                               tell ["_sizes[", show v, "]; "]
                               call genVariable ops i
                               tell ["++) {\n"]
                            | (v, i) <- zip [0..] indices]
                 p
                 sequence_ [tell ["}\n"] | _ <- indices]
            Nothing -> return ()

-- | Generate code for one of the Structured types.
cgenStructured :: GenOps -> A.Structured -> (A.Structured -> CGen ()) -> CGen ()
cgenStructured ops (A.Rep _ rep s) def = call genReplicator ops rep (call genStructured ops s def)
cgenStructured ops (A.Spec _ spec s) def = call genSpec ops spec (call genStructured ops s def)
cgenStructured ops (A.ProcThen _ p s) def = call genProcess ops p >> call genStructured ops s def
cgenStructured ops (A.Several _ ss) def = sequence_ [call genStructured ops s def | s <- ss]
cgenStructured _ s def = def s

--}}}

--{{{  metadata
-- | Turn a Meta into a string literal that can be passed to a function
-- expecting a const char * argument.
genMeta :: Meta -> CGen ()
genMeta m = tell ["\"", show m, "\""]
--}}}

--{{{  names
nameString :: A.Name -> String
nameString n = [if c == '.' then '_' else c | c <- A.nameName n]

genName :: A.Name -> CGen ()
genName n = tell [nameString n]
--}}}

--{{{  types
-- | If a type maps to a simple C type, return Just that; else return Nothing.
cgetScalarType :: GenOps -> A.Type -> Maybe String
cgetScalarType _ A.Bool = Just "bool"
cgetScalarType _ A.Byte = Just "uint8_t"
cgetScalarType _ A.UInt16 = Just "uint16_t"
cgetScalarType _ A.UInt32 = Just "uint32_t"
cgetScalarType _ A.UInt64 = Just "uint64_t"
cgetScalarType _ A.Int8 = Just "int8_t"
cgetScalarType _ A.Int = Just "int"
cgetScalarType _ A.Int16 = Just "int16_t"
cgetScalarType _ A.Int32 = Just "int32_t"
cgetScalarType _ A.Int64 = Just "int64_t"
cgetScalarType _ A.Real32 = Just "float"
cgetScalarType _ A.Real64 = Just "double"
cgetScalarType _ A.Timer = Just "Time"
cgetScalarType _ _ = Nothing

cgenType :: GenOps -> A.Type -> CGen ()
cgenType ops (A.Array _ t)
    =  do call genType ops t
          tell ["*"]
cgenType _ (A.Record n) = genName n
-- UserProtocol -- not used
cgenType _ (A.Chan _ _ t) = tell ["Channel *"]
-- Counted -- not used
-- Any -- not used
--cgenType ops (A.Port t) =
cgenType ops t
    = case call getScalarType ops t of
        Just s -> tell [s]
        Nothing -> call genMissing ops $ "genType " ++ show t

-- | Generate the number of bytes in a type that must have a fixed size.
cgenBytesIn :: GenOps -> A.Type -> Maybe A.Variable -> CGen ()
cgenBytesIn ops t v
    =  do free <- call genBytesIn' ops t v
          case free of
            Nothing -> return ()
            Just _ -> die "genBytesIn type with unknown dimension"

-- | Generate the number of bytes in a type that may have one free dimension.
cgenBytesIn' :: GenOps -> A.Type -> Maybe A.Variable -> CGen (Maybe Int)
cgenBytesIn' ops (A.Array ds t) v
    =  do free <- genBytesInArray ds 0
          call genBytesIn' ops t v
          return free
  where
    genBytesInArray [] _ = return Nothing
    genBytesInArray ((A.Dimension n):ds) i
        = do free <- genBytesInArray ds (i + 1)
             tell [show n, " * "]
             return free
    genBytesInArray (A.UnknownDimension:ds) i
        = case v of
            Just rv ->
              do free <- genBytesInArray ds (i + 1)
                 call genVariable ops rv
                 tell ["_sizes[", show i, "] * "]
                 return free
            Nothing ->
              do free <- genBytesInArray ds (i + 1)
                 case free of
                   Nothing -> return $ Just i
                   Just _ -> die "genBytesIn' type with more than one free dimension"
cgenBytesIn' _ (A.Record n) _
    =  do tell ["sizeof ("]
          genName n
          tell [")"]
          return Nothing
-- This is so that we can do RETYPES checks on channels; we don't actually
-- allow retyping between channels and other things.
cgenBytesIn' _ (A.Chan {}) _
    =  do tell ["sizeof (Channel *)"]
          return Nothing
cgenBytesIn' ops t _
    = case call getScalarType ops t of
        Just s -> tell ["sizeof (", s, ")"] >> return Nothing
        Nothing -> die $ "genBytesIn' " ++ show t
--}}}

--{{{  declarations
cgenDeclType :: GenOps -> A.AbbrevMode -> A.Type -> CGen ()
cgenDeclType ops am t
    =  do when (am == A.ValAbbrev) $ tell ["const "]
          call genType ops t
          case t of
            A.Array _ _ -> return ()
            A.Chan {} -> return ()
            A.Record _ -> tell [" *"]
            _ -> when (am == A.Abbrev) $ tell [" *"]

cgenDecl :: GenOps -> A.AbbrevMode -> A.Type -> A.Name -> CGen ()
cgenDecl ops am t n
    =  do call genDeclType ops am t
          tell [" "]
          genName n
--}}}

--{{{  conversions
cgenCheckedConversion :: GenOps -> Meta -> A.Type -> A.Type -> CGen () -> CGen ()
cgenCheckedConversion ops m fromT toT exp
    =  do tell ["(("]
          call genType ops toT
          tell [") "]
          if isSafeConversion fromT toT
            then exp
            else do call genTypeSymbol ops "range_check" fromT
                    tell [" ("]
                    call genTypeSymbol ops "mostneg" toT
                    tell [", "]
                    call genTypeSymbol ops "mostpos" toT
                    tell [", "]
                    exp
                    tell [", "]
                    genMeta m
                    tell [")"]
          tell [")"]

cgenConversion :: GenOps -> Meta -> A.ConversionMode -> A.Type -> A.Expression -> CGen ()
cgenConversion ops m A.DefaultConversion toT e
    =  do fromT <- typeOfExpression e
          call genCheckedConversion ops m fromT toT (call genExpression ops e)
cgenConversion ops m cm toT e
    =  do fromT <- typeOfExpression e
          case (isSafeConversion fromT toT, isRealType fromT, isRealType toT) of
            (True, _, _) ->
              -- A safe conversion -- no need for a check.
              call genCheckedConversion ops m fromT toT (call genExpression ops e)
            (_, True, True) ->
              -- Real to real.
              do call genConversionSymbol ops fromT toT cm
                 tell [" ("]
                 call genExpression ops e
                 tell [", "]
                 genMeta m
                 tell [")"]
            (_, True, False) ->
              -- Real to integer -- do real -> int64_t -> int.
              do let exp = do call genConversionSymbol ops fromT A.Int64 cm
                              tell [" ("]
                              call genExpression ops e
                              tell [", "]
                              genMeta m
                              tell [")"]
                 call genCheckedConversion ops m A.Int64 toT exp
            (_, False, True) ->
              -- Integer to real -- do int -> int64_t -> real.
              do call genConversionSymbol ops A.Int64 toT cm
                 tell [" ("]
                 call genCheckedConversion ops m fromT A.Int64 (call genExpression ops e)
                 tell [", "]
                 genMeta m
                 tell [")"]
            _ -> call genMissing ops $ "genConversion " ++ show cm

cgenConversionSymbol :: GenOps -> A.Type -> A.Type -> A.ConversionMode -> CGen ()
cgenConversionSymbol ops fromT toT cm
    =  do tell ["occam_convert_"]
          call genType ops fromT
          tell ["_"]
          call genType ops toT
          tell ["_"]
          case cm of
            A.Round -> tell ["round"]
            A.Trunc -> tell ["trunc"]
--}}}

--{{{  literals
cgenLiteral :: GenOps -> A.LiteralRepr -> CGen ()
cgenLiteral ops lr
    = if isStringLiteral lr
        then do tell ["\""]
                let A.ArrayLiteral _ aes = lr
                sequence_ [genByteLiteral s
                           | A.ArrayElemExpr (A.Literal _ _ (A.ByteLiteral _ s)) <- aes]
                tell ["\""]
        else call genLiteralRepr ops lr

-- | Does a LiteralRepr represent something that can be a plain string literal?
isStringLiteral :: A.LiteralRepr -> Bool
isStringLiteral (A.ArrayLiteral _ aes)
    = and [case ae of
             A.ArrayElemExpr (A.Literal _ _ (A.ByteLiteral _ _)) -> True
             _ -> False
           | ae <- aes]
isStringLiteral _ = False

cgenLiteralRepr :: GenOps -> A.LiteralRepr -> CGen ()
cgenLiteralRepr _ (A.RealLiteral m s) = tell [s]
cgenLiteralRepr _ (A.IntLiteral m s) = genDecimal s
cgenLiteralRepr _ (A.HexLiteral m s) = tell ["0x", s]
cgenLiteralRepr ops (A.ByteLiteral m s) = tell ["'"] >> genByteLiteral s >> tell ["'"]
cgenLiteralRepr ops (A.ArrayLiteral m aes)
    =  do genLeftB
          call genArrayLiteralElems ops aes
          genRightB
cgenLiteralRepr ops (A.RecordLiteral _ es)
    =  do genLeftB
          seqComma $ map (call genUnfoldedExpression ops) es
          genRightB

-- | Generate an expression inside a record literal.
--
-- This is awkward: the sort of literal that this produces when there's a
-- variable in here cannot always be compiled at the top level of a C99 program
-- -- because in C99, an array subscript is not a constant, even if it's a
-- constant subscript of a constant array.  So we need to be sure that when we
-- use this at the top level, the thing we're unfolding only contains literals.
-- Yuck!
cgenUnfoldedExpression :: GenOps -> A.Expression -> CGen ()
cgenUnfoldedExpression ops (A.Literal _ t lr)
    =  do call genLiteralRepr ops lr
          case t of
            A.Array ds _ ->
              do genComma
                 genLeftB
                 call genArraySizesLiteral ops ds
                 genRightB
            _ -> return ()
cgenUnfoldedExpression ops (A.ExprVariable m var) = call genUnfoldedVariable ops m var
cgenUnfoldedExpression ops e = call genExpression ops e

-- | Generate a variable inside a record literal.
cgenUnfoldedVariable :: GenOps -> Meta -> A.Variable -> CGen ()
cgenUnfoldedVariable ops m var
    =  do t <- typeOfVariable var
          case t of
            A.Array ds _ ->
              do genLeftB
                 unfoldArray ds var
                 genRightB
                 genComma
                 genLeftB
                 call genArraySizesLiteral ops ds
                 genRightB
            A.Record _ ->
              do genLeftB
                 fs <- recordFields m t
                 seqComma [call genUnfoldedVariable ops m (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
                 genRightB
            -- We can defeat the usage check here because we know it's safe; *we're*
            -- generating the subscripts.
            -- FIXME Is that actually true for something like [a[x]]?
            _ -> call genVariable' ops False var
  where
    unfoldArray :: [A.Dimension] -> A.Variable -> CGen ()
    unfoldArray [] v = call genUnfoldedVariable ops m v
    unfoldArray (A.Dimension n:ds) v
      = seqComma $ [unfoldArray ds (A.SubscriptedVariable m (A.Subscript m $ makeConstant m i) v)
                    | i <- [0..(n - 1)]]
    unfoldArray _ _ = dieP m "trying to unfold array with unknown dimension"

-- | Generate a decimal literal -- removing leading zeroes to avoid producing
-- an octal literal!
genDecimal :: String -> CGen ()
genDecimal "0" = tell ["0"]
genDecimal ('0':s) = genDecimal s
genDecimal ('-':s) = tell ["-"] >> genDecimal s
genDecimal s = tell [s]

cgenArrayLiteralElems :: GenOps -> [A.ArrayElem] -> CGen ()
cgenArrayLiteralElems ops aes
    = seqComma $ map genElem aes
  where
    genElem :: A.ArrayElem -> CGen ()
    genElem (A.ArrayElemArray aes) = call genArrayLiteralElems ops aes
    genElem (A.ArrayElemExpr e) = call genUnfoldedExpression ops e

genByteLiteral :: String -> CGen ()
genByteLiteral s
    =  do c <- evalByte s
          tell [convByte c]

convByte :: Char -> String
convByte '\'' = "\\'"
convByte '"' = "\\\""
convByte '\\' = "\\\\"
convByte '\r' = "\\r"
convByte '\n' = "\\n"
convByte '\t' = "\\t"
convByte c
  | o == 0              = "\\0"
  | (o < 32 || o > 127) = printf "\\%03o" o
  | otherwise           = [c]
  where o = ord c
--}}}

--{{{  variables
{-
The various types are generated like this:

                        ================= Use =================
                        Original        ValAbbrev   Abbrev
                        --------------------------------------
INT x:                  int x;          int x;      int *x;
  x                     x               x           *x

[10]INT xs:             int xs[10];     int *xs;    int *xs;
  xs                    xs              xs          xs
  xs[i]                 xs[i]           xs[i]       xs[i]

[20][10]INT xss:        int xss[20*10]; int *xss;   int *xss;
  xss                   xss             xss         xss
  xss[i]                &xss[i*10]      &xss[i*10]  &xss[i*10]  (where 10 = xss_sizes[1])
  xss[i][j]             xss[i*10+j]     xss[i*10+j] xss[i*10+j]

[6][4][2]INT xsss:      int xsss[6*4*2]; int *xsss;
  xsss                  xsss             (as left)
  xsss[i]               &xsss[i*4*2]
  xsss[i][j]            &xsss[i*4*2+j*2]
  xsss[i][j][k]         xsss[i*4*2+j*2+k]

MYREC r:                MYREC r;        MYREC *r;   MYREC *r;
  r                     &r              r           r
  r[F]                  (&r)->F         (r)->F      (r)->F

[10]MYREC rs:           MYREC rs[10];   MYREC *rs;  MYREC *rs;
  rs                    rs              rs          rs
  rs[i]                 &rs[i]          &rs[i]      &rs[i]
  rs[i][F]              (&rs[i])->F     (&rs[i])->F (&rs[i])->F
                           -- depending on what F is -- if it's another record...

CHAN OF INT c:          Channel c;                  Channel *c;
  c                     &c                          c

[10]CHAN OF INT cs:     Channel **cs;               Channel **cs;
  cs                    cs                          cs
  cs[i]                 cs[i]                       cs[i]

I suspect there's probably a nicer way of doing this, but as a translation of
the above table this isn't too horrible...
-}
-- | Generate C code for a variable.
cgenVariable :: GenOps -> A.Variable -> CGen ()
cgenVariable ops = call genVariable' ops True

-- | Generate C code for a variable without doing any range checks.
cgenVariableUnchecked :: GenOps -> A.Variable -> CGen ()
cgenVariableUnchecked ops = call genVariable' ops False

-- FIXME This needs to detect when we've "gone through" a record and revert to
-- the Original prefixing behaviour. (Can do the same for arrays?)
-- Best way to do this is probably to make inner return a reference and a prefix,
-- so that we can pass prefixes upwards...
cgenVariable' :: GenOps -> Bool -> A.Variable -> CGen ()
cgenVariable' ops checkValid v
    =  do am <- accessAbbrevMode v
          t <- typeOfVariable v
          let isSub = case v of
                        A.Variable _ _ -> False
                        A.SubscriptedVariable _ _ _ -> True
                        A.DirectedVariable _ _ _ -> False

          let prefix = case (am, t) of
                         (_, A.Array _ _) -> ""
                         (A.Original, A.Chan {}) -> if isSub then "" else "&"
                         (A.Abbrev, A.Chan {}) -> ""
                         (A.Original, A.Record _) -> "&"
                         (A.Abbrev, A.Record _) -> ""
                         (A.Abbrev, _) -> "*"
                         _ -> ""

          when (prefix /= "") $ tell ["(", prefix]
          inner v
          when (prefix /= "") $ tell [")"]
  where
    -- | Find the effective abbreviation mode for the variable we're looking at.
    -- This differs from abbrevModeOfVariable in that it will return Original
    -- for array and record elements (because when we're generating C, we can
    -- treat c->x as if it's just x).
    accessAbbrevMode :: A.Variable -> CGen A.AbbrevMode
    accessAbbrevMode (A.Variable _ n) = abbrevModeOfName n
    accessAbbrevMode (A.SubscriptedVariable _ sub v)
        =  do am <- accessAbbrevMode v
              return $ case (am, sub) of
                         (_, A.Subscript _ _) -> A.Original
                         (_, A.SubscriptField _ _) -> A.Original
                         _ -> am

    inner :: A.Variable -> CGen ()
    inner (A.Variable _ n) = genName n
    inner (A.DirectedVariable _ _ v) = inner v
    inner sv@(A.SubscriptedVariable _ (A.Subscript _ _) _)
        =  do let (es, v) = collectSubs sv
              call genVariable ops v
              call genArraySubscript ops checkValid v es
    inner (A.SubscriptedVariable _ (A.SubscriptField m n) v)
        =  do call genVariable ops v
              tell ["->"]
              genName n
    inner (A.SubscriptedVariable m (A.SubscriptFromFor m' start _) v)
        = inner (A.SubscriptedVariable m (A.Subscript m' start) v)
    inner (A.SubscriptedVariable m (A.SubscriptFrom m' start) v)
        = inner (A.SubscriptedVariable m (A.Subscript m' start) v)
    inner (A.SubscriptedVariable m (A.SubscriptFor m' _) v)
        = inner (A.SubscriptedVariable m (A.Subscript m' (makeConstant m' 0)) v)

    -- | Collect all the plain subscripts on a variable, so we can combine them.
    collectSubs :: A.Variable -> ([A.Expression], A.Variable)
    collectSubs (A.SubscriptedVariable _ (A.Subscript _ e) v)
        = (es' ++ [e], v')
      where
        (es', v') = collectSubs v
    collectSubs v = ([], v)

cgenArraySubscript :: GenOps -> Bool -> A.Variable -> [A.Expression] -> CGen ()
cgenArraySubscript ops checkValid v es
    =  do t <- typeOfVariable v
          let numDims = case t of A.Array ds _ -> length ds
          tell ["["]
          sequence_ $ intersperse (tell [" + "]) $ genPlainSub v es [0..(numDims - 1)]
          tell ["]"]
  where
    -- | Generate the individual offsets that need adding together to find the
    -- right place in the array.
    -- FIXME This is obviously not the best way to factor this, but I figure a
    -- smart C compiler should be able to work it out...
    genPlainSub :: A.Variable -> [A.Expression] -> [Int] -> [CGen ()]
    genPlainSub _ [] _ = []
    genPlainSub v (e:es) (sub:subs)
        = gen : genPlainSub v es subs
      where
        gen = sequence_ $ intersperse (tell [" * "]) $ genSub : genChunks
        genSub
            = if checkValid
                then do tell ["occam_check_index ("]
                        call genExpression ops e
                        tell [", "]
                        call genVariable ops v
                        tell ["_sizes[", show sub, "], "]
                        genMeta (findMeta e)
                        tell [")"]
                else call genExpression ops e
        genChunks = [call genVariable ops v >> tell ["_sizes[", show i, "]"] | i <- subs]
--}}}

--{{{  expressions
cgenExpression :: GenOps -> A.Expression -> CGen ()
cgenExpression ops (A.Monadic m op e) = call genMonadic ops m op e
cgenExpression ops (A.Dyadic m op e f) = call genDyadic ops m op e f
cgenExpression ops (A.MostPos m t) = call genTypeSymbol ops "mostpos" t
cgenExpression ops (A.MostNeg m t) = call genTypeSymbol ops "mostneg" t
--cgenExpression ops (A.SizeType m t)
cgenExpression ops (A.SizeExpr m e)
    =  do call genExpression ops e
          call genSizeSuffix ops "0"
cgenExpression ops (A.SizeVariable m v)
    =  do call genVariable ops v
          call genSizeSuffix ops "0"
cgenExpression ops (A.Conversion m cm t e) = call genConversion ops m cm t e
cgenExpression ops (A.ExprVariable m v) = call genVariable ops v
cgenExpression ops (A.Literal _ _ lr) = call genLiteral ops lr
cgenExpression _ (A.True m) = tell ["true"]
cgenExpression _ (A.False m) = tell ["false"]
--cgenExpression ops (A.FunctionCall m n es)
cgenExpression ops (A.IntrinsicFunctionCall m s es) = call genIntrinsicFunction ops m s es
--cgenExpression ops (A.SubscriptedExpr m s e)
--cgenExpression ops (A.BytesInExpr m e)
cgenExpression ops (A.BytesInType m t) = call genBytesIn ops t Nothing
--cgenExpression ops (A.OffsetOf m t n)
cgenExpression ops t = call genMissing ops $ "genExpression " ++ show t

cgenSizeSuffix :: GenOps -> String -> CGen ()
cgenSizeSuffix _ dim = tell ["_sizes[", dim, "]"]

cgenTypeSymbol :: GenOps -> String -> A.Type -> CGen ()
cgenTypeSymbol ops s t
    = case call getScalarType ops t of
        Just ct -> tell ["occam_", s, "_", ct]
        Nothing -> call genMissing ops $ "genTypeSymbol " ++ show t

cgenIntrinsicFunction :: GenOps -> Meta -> String -> [A.Expression] -> CGen ()
cgenIntrinsicFunction ops m s es
    =  do tell ["occam_", s, " ("]
          sequence [call genExpression ops e >> genComma | e <- es]
          genMeta m
          tell [")"]
--}}}

--{{{  operators
cgenSimpleMonadic :: GenOps -> String -> A.Expression -> CGen ()
cgenSimpleMonadic ops s e
    =  do tell ["(", s]
          call genExpression ops e
          tell [")"]

cgenFuncMonadic :: GenOps -> Meta -> String -> A.Expression -> CGen ()
cgenFuncMonadic ops m s e
    =  do t <- typeOfExpression e
          call genTypeSymbol ops s t
          tell [" ("]
          call genExpression ops e
          tell [", "]
          genMeta m
          tell [")"]

cgenMonadic :: GenOps -> Meta -> A.MonadicOp -> A.Expression -> CGen ()
cgenMonadic ops m A.MonadicSubtr e = call genFuncMonadic ops m "negate" e
cgenMonadic ops _ A.MonadicMinus e = call genSimpleMonadic ops "-" e
cgenMonadic ops _ A.MonadicBitNot e = call genSimpleMonadic ops "~" e
cgenMonadic ops _ A.MonadicNot e = call genSimpleMonadic ops "!" e

cgenSimpleDyadic :: GenOps -> String -> A.Expression -> A.Expression -> CGen ()
cgenSimpleDyadic ops s e f
    =  do tell ["("]
          call genExpression ops e
          tell [" ", s, " "]
          call genExpression ops f
          tell [")"]

cgenFuncDyadic :: GenOps -> Meta -> String -> A.Expression -> A.Expression -> CGen ()
cgenFuncDyadic ops m s e f
    =  do t <- typeOfExpression e
          call genTypeSymbol ops s t
          tell [" ("]
          call genExpression ops e
          tell [", "]
          call genExpression ops f
          tell [", "]
          genMeta m
          tell [")"]

cgenDyadic :: GenOps -> Meta -> A.DyadicOp -> A.Expression -> A.Expression -> CGen ()
cgenDyadic ops m A.Add e f = call genFuncDyadic ops m "add" e f
cgenDyadic ops m A.Subtr e f = call genFuncDyadic ops m "subtr" e f
cgenDyadic ops m A.Mul e f = call genFuncDyadic ops m "mul" e f
cgenDyadic ops m A.Div e f = call genFuncDyadic ops m "div" e f
cgenDyadic ops m A.Rem e f = call genFuncDyadic ops m "rem" e f
cgenDyadic ops _ A.Plus e f = call genSimpleDyadic ops "+" e f
cgenDyadic ops _ A.Minus e f = call genSimpleDyadic ops "-" e f
cgenDyadic ops _ A.Times e f = call genSimpleDyadic ops "*" e f
cgenDyadic ops _ A.LeftShift e f = call genSimpleDyadic ops "<<" e f
cgenDyadic ops _ A.RightShift e f = call genSimpleDyadic ops ">>" e f
cgenDyadic ops _ A.BitAnd e f = call genSimpleDyadic ops "&" e f
cgenDyadic ops _ A.BitOr e f = call genSimpleDyadic ops "|" e f
cgenDyadic ops _ A.BitXor e f = call genSimpleDyadic ops "^" e f
cgenDyadic ops _ A.And e f = call genSimpleDyadic ops "&&" e f
cgenDyadic ops _ A.Or e f = call genSimpleDyadic ops "||" e f
cgenDyadic ops _ A.Eq e f = call genSimpleDyadic ops "==" e f
cgenDyadic ops _ A.NotEq e f = call genSimpleDyadic ops "!=" e f
cgenDyadic ops _ A.Less e f = call genSimpleDyadic ops "<" e f
cgenDyadic ops _ A.More e f = call genSimpleDyadic ops ">" e f
cgenDyadic ops _ A.LessEq e f = call genSimpleDyadic ops "<=" e f
cgenDyadic ops _ A.MoreEq e f = call genSimpleDyadic ops ">=" e f
--}}}

--{{{  input/output items
cgenInputItem :: GenOps -> A.Variable -> A.InputItem -> CGen ()
cgenInputItem ops c (A.InCounted m cv av)
    =  do call genInputItem ops c (A.InVariable m cv)
          t <- typeOfVariable av
          tell ["ChanIn ("]
          call genVariable ops c
          tell [", "]
          fst $ abbrevVariable ops A.Abbrev t av
          tell [", "]
          subT <- trivialSubscriptType t
          call genVariable ops cv
          tell [" * "]
          call genBytesIn ops subT (Just av)
          tell [");\n"]
cgenInputItem ops c (A.InVariable m v)
    =  do t <- typeOfVariable v
          let rhs = fst $ abbrevVariable ops A.Abbrev t v
          case t of
            A.Int ->
              do tell ["ChanInInt ("]
                 call genVariable ops c
                 tell [", "]
                 rhs
                 tell [");\n"]
            _ ->
              do tell ["ChanIn ("]
                 call genVariable ops c
                 tell [", "]
                 rhs
                 tell [", "]
                 call genBytesIn ops t (Just v)
                 tell [");\n"]

cgenOutputItem :: GenOps -> A.Variable -> A.OutputItem -> CGen ()
cgenOutputItem ops c (A.OutCounted m ce ae)
    =  do call genOutputItem ops c (A.OutExpression m ce)
          t <- typeOfExpression ae
          case ae of
            A.ExprVariable m v ->
              do tell ["ChanOut ("]
                 call genVariable ops c
                 tell [", "]
                 fst $ abbrevVariable ops A.Abbrev t v
                 tell [", "]
                 subT <- trivialSubscriptType t
                 call genExpression ops ce
                 tell [" * "]
                 call genBytesIn ops subT (Just v)
                 tell [");\n"]
cgenOutputItem ops c (A.OutExpression m e)
    =  do t <- typeOfExpression e
          case (t, e) of
            (A.Int, _) ->
              do tell ["ChanOutInt ("]
                 call genVariable ops c
                 tell [", "]
                 call genExpression ops e
                 tell [");\n"]
            (_, A.ExprVariable _ v) ->
              do tell ["ChanOut ("]
                 call genVariable ops c
                 tell [", "]
                 fst $ abbrevVariable ops A.Abbrev t v
                 tell [", "]
                 call genBytesIn ops t (Just v)
                 tell [");\n"]
            _ ->
              do n <- makeNonce "output_item"
                 tell ["const "]
                 call genType ops t
                 tell [" ", n, " = "]
                 call genExpression ops e
                 tell [";\n"]
                 tell ["ChanOut ("]
                 call genVariable ops c
                 tell [", &", n, ", "]
                 call genBytesIn ops t Nothing
                 tell [");\n"]
--}}}

--{{{  replicators
cgenReplicator :: GenOps -> A.Replicator -> CGen () -> CGen ()
cgenReplicator ops rep body
    =  do tell ["for ("]
          call genReplicatorLoop ops rep
          tell [") {\n"]
          body
          tell ["}\n"]

isZero :: A.Expression -> Bool
isZero (A.Literal _ A.Int (A.IntLiteral _ "0")) = True
isZero _ = False

cgenReplicatorLoop :: GenOps -> A.Replicator -> CGen ()
cgenReplicatorLoop ops (A.For m index base count)
    = if isZero base
        then simple
        else general
  where
    simple :: CGen ()
    simple
        =  do tell ["int "]
              genName index
              tell [" = 0; "]
              genName index
              tell [" < "]
              call genExpression ops count
              tell ["; "]
              genName index
              tell ["++"]

    general :: CGen ()
    general
        =  do counter <- makeNonce "replicator_count"
              tell ["int ", counter, " = "]
              call genExpression ops count
              tell [", "]
              genName index
              tell [" = "]
              call genExpression ops base
              tell ["; ", counter, " > 0; ", counter, "--, "]
              genName index
              tell ["++"]

cgenReplicatorSize :: GenOps -> A.Replicator -> CGen ()
cgenReplicatorSize ops rep = call genExpression ops (sizeOfReplicator rep)
--}}}

--{{{  abbreviations
-- FIXME: This code is horrible, and I can't easily convince myself that it's correct.

cgenSlice :: GenOps -> A.Variable -> A.Variable -> A.Expression -> A.Expression -> [A.Dimension] -> (CGen (), A.Name -> CGen ())
cgenSlice ops v (A.Variable _ on) start count ds
       -- We need to disable the index check here because we might be taking
       -- element 0 of a 0-length array -- which is valid.
    = (tell ["&"] >> call genVariableUnchecked ops v,
       call genArraySize ops False
                    (do tell ["occam_check_slice ("]
                        call genExpression ops start
                        tell [", "]
                        call genExpression ops count
                        tell [", "]
                        genName on
                        tell ["_sizes[0], "]
                        genMeta (findMeta count)
                        tell [")"]
                        sequence_ [do tell [", "]
                                      genName on
                                      tell ["_sizes[", show i, "]"]
                                   | i <- [1..(length ds - 1)]]))

cgenArrayAbbrev :: GenOps -> A.Variable -> (CGen (), A.Name -> CGen ())
cgenArrayAbbrev ops v
    = (tell ["&"] >> call genVariable ops v, genAASize v 0)
  where
    genAASize (A.SubscriptedVariable _ (A.Subscript _ _) v) arg
        = genAASize v (arg + 1)
    genAASize (A.Variable _ on) arg
        = call genArraySize ops True
                       (tell ["&"] >> genName on >> tell ["_sizes[", show arg, "]"])
    genAASize (A.DirectedVariable _ _ v)  arg
        = genAASize v arg

cgenArraySize :: GenOps -> Bool -> CGen () -> A.Name -> CGen ()
cgenArraySize ops isPtr size n
    = if isPtr
        then do tell ["const int *"]
                genName n
                tell ["_sizes = "]
                size
                tell [";\n"]
        else do tell ["const int "]
                genName n
                tell ["_sizes[] = { "]
                size
                tell [" };\n"]

noSize :: A.Name -> CGen ()
noSize n = return ()

cgenVariableAM :: GenOps -> A.Variable -> A.AbbrevMode -> CGen ()
cgenVariableAM ops v am
    =  do when (am == A.Abbrev) $ tell ["&"]
          call genVariable ops v

-- | Generate the right-hand side of an abbreviation of a variable.
abbrevVariable :: GenOps -> A.AbbrevMode -> A.Type -> A.Variable -> (CGen (), A.Name -> CGen ())
abbrevVariable ops am (A.Array _ _) v@(A.SubscriptedVariable _ (A.Subscript _ _) _)
    = call genArrayAbbrev ops v
abbrevVariable ops am (A.Array ds _) v@(A.SubscriptedVariable _ (A.SubscriptFromFor _ start count) v')
    = call genSlice ops v v' start count ds
abbrevVariable ops am (A.Array ds _) v@(A.SubscriptedVariable m (A.SubscriptFrom _ start) v')
    = call genSlice ops v v' start (A.Dyadic m A.Minus (A.SizeExpr m (A.ExprVariable m v')) start) ds
abbrevVariable ops am (A.Array ds _) v@(A.SubscriptedVariable m (A.SubscriptFor _ count) v')
    = call genSlice ops v v' (makeConstant m 0) count ds
abbrevVariable ops am (A.Array _ _) v
    = (call genVariable ops v, call genArraySize ops True (call genVariable ops v >> tell ["_sizes"]))
abbrevVariable ops am (A.Chan {}) v
    = (call genVariable ops v, noSize)
abbrevVariable ops am (A.Record _) v
    = (call genVariable ops v, noSize)
abbrevVariable ops am t v
    = (call genVariableAM ops v am, noSize)

-- | Generate the size part of a RETYPES\/RESHAPES abbrevation of a variable.
cgenRetypeSizes :: GenOps -> Meta -> A.AbbrevMode -> A.Type -> A.Name -> A.Type -> A.Variable -> CGen ()
cgenRetypeSizes ops m am destT destN srcT srcV
    =  do size <- makeNonce "retype_size"
          tell ["int ", size, " = occam_check_retype ("]
          call genBytesIn ops srcT (Just srcV)
          tell [", "]
          free <- call genBytesIn' ops destT Nothing
          tell [", "]
          genMeta m
          tell [");\n"]

          case destT of
            -- An array -- figure out the genMissing dimension, if there is one.
            A.Array destDS _ ->
              do case free of
                   -- No free dimensions; check the complete array matches in size.
                   Nothing ->
                     do tell ["if (", size, " != 1) {\n"]
                        call genStop ops m "array size mismatch in RETYPES"
                        tell ["}\n"]
                   _ -> return ()

                 let dims = [case d of
                               A.UnknownDimension ->
                                 -- Unknown dimension -- insert it.
                                 case free of
                                   Just _ -> tell [size]
                                   Nothing ->
                                     die "genRetypeSizes expecting free dimension"
                               A.Dimension n -> tell [show n]
                             | d <- destDS]
                 call genArraySize ops False (seqComma dims) destN

            -- Not array; just check the size is 1.
            _ ->
              do tell ["if (", size, " != 1) {\n"]
                 call genStop ops m "size mismatch in RETYPES"
                 tell ["}\n"]

-- | Generate the right-hand side of an abbreviation of an expression.
abbrevExpression :: GenOps -> A.AbbrevMode -> A.Type -> A.Expression -> (CGen (), A.Name -> CGen ())
abbrevExpression ops am t@(A.Array _ _) e
    = case e of
        A.ExprVariable _ v -> abbrevVariable ops am t v
        A.Literal _ (A.Array ds _) r -> (call genExpression ops e, call declareArraySizes ops ds)
        _ -> bad
  where
    bad = (call genMissing ops "array expression abbreviation", noSize)
abbrevExpression ops am _ e
    = (call genExpression ops e, noSize)
--}}}

--{{{  specifications
cgenSpec :: GenOps -> A.Specification -> CGen () -> CGen ()
cgenSpec ops spec body
    =  do call introduceSpec ops spec
          body
          call removeSpec ops spec

-- | Generate the C type corresponding to a variable being declared.
-- It must be possible to use this in arrays.
cdeclareType :: GenOps -> A.Type -> CGen ()
cdeclareType _ (A.Chan {}) = tell ["Channel *"]
cdeclareType ops t = call genType ops t

-- | Generate a declaration of a new variable.
cgenDeclaration :: GenOps -> A.Type -> A.Name -> CGen ()
cgenDeclaration ops (A.Chan {}) n
    =  do tell ["Channel "]
          genName n
          tell [";\n"]
cgenDeclaration ops (A.Array ds t) n
    =  do call declareType ops t
          tell [" "]
          genName n
          call genFlatArraySize ops ds
          tell [";\n"]
          call declareArraySizes ops ds n
cgenDeclaration ops t n
    =  do call declareType ops t
          tell [" "]
          genName n
          tell [";\n"]

-- | Generate the size of the C array that an occam array of the given
-- dimensions maps to.
cgenFlatArraySize :: GenOps -> [A.Dimension] -> CGen ()
cgenFlatArraySize ops ds
    =  do tell ["["]
          sequence $ intersperse (tell [" * "])
                                 [case d of A.Dimension n -> tell [show n] | d <- ds]
          tell ["]"]

-- | Generate the size of the _sizes C array for an occam array.
cgenArraySizesSize :: GenOps -> [A.Dimension] -> CGen ()
cgenArraySizesSize ops ds
    =  do tell ["["]
          tell [show $ length ds]
          tell ["]"]

-- | Declare an _sizes array for a variable.
cdeclareArraySizes :: GenOps -> [A.Dimension] -> A.Name -> CGen ()
cdeclareArraySizes ops ds name
    = call genArraySize ops False (call genArraySizesLiteral ops ds) name

-- | Generate a C literal to initialise an _sizes array with, where all the
-- dimensions are fixed.
cgenArraySizesLiteral :: GenOps -> [A.Dimension] -> CGen ()
cgenArraySizesLiteral ops ds
    = seqComma dims
  where
    dims :: [CGen ()]
    dims = [case d of
              A.Dimension n -> tell [show n]
              _ -> die "unknown dimension in array type"
            | d <- ds]

-- | Initialise an item being declared.
cdeclareInit :: GenOps -> Meta -> A.Type -> A.Variable -> Maybe (CGen ())
cdeclareInit ops _ (A.Chan {}) var
    = Just $ do tell ["ChanInit ("]
                call genVariable ops var
                tell [");\n"]
cdeclareInit ops m t@(A.Array ds t') var
    = Just $ do init <- case t' of
                          A.Chan {} ->
                            do A.Specification _ store _ <- makeNonceVariable "storage" m (A.Array ds A.Int) A.VariableName A.Original
                               let storeV = A.Variable m store
                               tell ["Channel "]
                               genName store
                               call genFlatArraySize ops ds
                               tell [";\n"]
                               call declareArraySizes ops ds store
                               return (\sub -> Just $ do call genVariable ops (sub var)
                                                         tell [" = &"]
                                                         call genVariable ops (sub storeV)
                                                         tell [";\n"]
                                                         doMaybe $ call declareInit ops m t' (sub var))
                          _ -> return (\sub -> call declareInit ops m t' (sub var))
                call genOverArray ops m var init
cdeclareInit ops m rt@(A.Record _) var
    = Just $ do fs <- recordFields m rt
                sequence_ [initField t (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
  where
    initField :: A.Type -> A.Variable -> CGen ()
    -- An array as a record field; we must initialise the sizes.
    initField t@(A.Array ds _) v
        =  do sequence_ [do call genVariable ops v
                            tell ["_sizes[", show i, "] = ", show n, ";\n"]
                         | (i, A.Dimension n) <- zip [0..(length ds - 1)] ds]
              doMaybe $ call declareInit ops m t v
    initField t v = doMaybe $ call declareInit ops m t v
cdeclareInit _ _ _ _ = Nothing

-- | Free a declared item that's going out of scope.
cdeclareFree :: GenOps -> Meta -> A.Type -> A.Variable -> Maybe (CGen ())
cdeclareFree _ _ _ _ = Nothing

{-
                  Original        Abbrev
INT x IS y:       int *x = &y;    int *x = &(*y);
[]INT xs IS ys:   int *xs = ys;   int *xs = ys;
                  const int xs_sizes[] = ys_sizes;

CHAN OF INT c IS d:       Channel *c = d;

[10]CHAN OF INT cs:       Channel tmp[10];
                          Channel *cs[10];
                          for (...) { cs[i] = &tmp[i]; ChanInit(cs[i]); }
                          const int cs_sizes[] = { 10 };
[]CHAN OF INT ds IS cs:   Channel **ds = cs;
                          const int *ds_sizes = cs_sizes;
-}
cintroduceSpec :: GenOps -> A.Specification -> CGen ()
cintroduceSpec ops (A.Specification m n (A.Declaration _ t))
    = do call genDeclaration ops t n
         case call declareInit ops m t (A.Variable m n) of
           Just p -> p
           Nothing -> return ()
cintroduceSpec ops (A.Specification _ n (A.Is _ am t v))
    =  do let (rhs, rhsSizes) = abbrevVariable ops am t v
          call genDecl ops am t n
          tell [" = "]
          rhs
          tell [";\n"]
          rhsSizes n
cintroduceSpec ops (A.Specification _ n (A.IsExpr _ am t e))
    =  do let (rhs, rhsSizes) = abbrevExpression ops am t e
          case (am, t, e) of
            (A.ValAbbrev, A.Array _ ts, A.Literal _ _ _) ->
              -- For "VAL []T a IS [vs]:", we have to use [] rather than * in the
              -- declaration, since you can't say "int *foo = {vs};" in C.
              do tell ["const "]
                 call genType ops ts
                 tell [" "]
                 genName n
                 tell ["[] = "]
                 rhs
                 tell [";\n"]
                 rhsSizes n
            (A.ValAbbrev, A.Record _, A.Literal _ _ _) ->
              -- Record literals are even trickier, because there's no way of
              -- directly writing a struct literal in C that you can use -> on.
              do tmp <- makeNonce "record_literal"
                 tell ["const "]
                 call genType ops t
                 tell [" ", tmp, " = "]
                 rhs
                 tell [";\n"]
                 call genDecl ops am t n
                 tell [" = &", tmp, ";\n"]
                 rhsSizes n
            _ ->
              do call genDecl ops am t n
                 tell [" = "]
                 rhs
                 tell [";\n"]
                 rhsSizes n
cintroduceSpec ops (A.Specification _ n (A.IsChannelArray _ t cs))
    =  do tell ["Channel *"]
          genName n
          tell ["[] = {"]
          seqComma (map (call genVariable ops) cs)
          tell ["};\n"]
          call declareArraySizes ops [A.Dimension $ length cs] n
cintroduceSpec _ (A.Specification _ _ (A.DataType _ _)) = return ()
cintroduceSpec ops (A.Specification _ n (A.RecordType _ b fs))
    =  do tell ["typedef struct {\n"]
          sequence_ [case t of
                       -- Arrays need the corresponding _sizes array.
                       A.Array ds t' ->
                         do call genType ops t'
                            tell [" "]
                            genName n
                            call genFlatArraySize ops ds
                            tell [";\n"]
                            tell ["int "]
                            genName n
                            tell ["_sizes"]
                            call genArraySizesSize ops ds
                            tell [";\n"]
                       _ -> call genDeclaration ops t n
                     | (n, t) <- fs]
          tell ["} "]
          when b $ tell ["occam_struct_packed "]
          genName n
          tell [";\n"]
cintroduceSpec _ (A.Specification _ n (A.Protocol _ _)) = return ()
cintroduceSpec ops (A.Specification _ n (A.ProtocolCase _ ts))
    =  do tell ["typedef enum {\n"]
          seqComma [genName tag >> tell ["_"] >> genName n | (tag, _) <- ts]
          -- You aren't allowed to have an empty enum.
          when (ts == []) $
            tell ["empty_protocol_"] >> genName n
          tell ["\n"]
          tell ["} "]
          genName n
          tell [";\n"]
cintroduceSpec ops (A.Specification _ n (A.Proc _ sm fs p))
    =  do call genSpecMode ops sm
          tell ["void "]
          genName n
          tell [" (Process *me"]
          call genFormals ops fs
          tell [") {\n"]
          call genProcess ops p
          tell ["}\n"]
cintroduceSpec ops (A.Specification _ n (A.Retypes m am t v))
    =  do origT <- typeOfVariable v
          let (rhs, _) = abbrevVariable ops A.Abbrev origT v
          call genDecl ops am t n
          tell [" = "]
          -- For scalar types that are VAL abbreviations (e.g. VAL INT64),
          -- we need to dereference the pointer that abbrevVariable gives us.
          let deref = case (am, t) of
                        (_, A.Array _ _) -> False
                        (_, A.Chan {}) -> False
                        (A.ValAbbrev, _) -> True
                        _ -> False
          when deref $ tell ["*"]
          tell ["("]
          call genDeclType ops am t
          when deref $ tell [" *"]
          tell [") "]
          rhs
          tell [";\n"]
          call genRetypeSizes ops m am t n origT v
--cintroduceSpec ops (A.Specification _ n (A.RetypesExpr _ am t e))
cintroduceSpec ops n = call genMissing ops $ "introduceSpec " ++ show n

cremoveSpec :: GenOps -> A.Specification -> CGen ()
cremoveSpec ops (A.Specification m n (A.Declaration _ t))
    = case t of
        A.Array _ t' -> call genOverArray ops m var (\sub -> call declareFree ops m t' (sub var))
        _ ->
          do case call declareFree ops m t var of
               Just p -> p
               Nothing -> return ()
  where
    var = A.Variable m n
cremoveSpec _ _ = return ()

cgenSpecMode :: GenOps -> A.SpecMode -> CGen ()
cgenSpecMode _ A.PlainSpec = return ()
cgenSpecMode _ A.InlineSpec = tell ["inline "]
--}}}

--{{{  actuals/formals
prefixComma :: [CGen ()] -> CGen ()
prefixComma cs = sequence_ [genComma >> c | c <- cs]

cgenActuals :: GenOps -> [A.Actual] -> CGen ()
cgenActuals ops as = prefixComma (map (call genActual ops) as)

cgenActual :: GenOps -> A.Actual -> CGen ()
cgenActual ops actual
    = case actual of
        A.ActualExpression t e ->
          case (t, e) of
            (A.Array _ _, A.ExprVariable _ v) ->
              do call genVariable ops v
                 tell [", "]
                 call genVariable ops v
                 tell ["_sizes"]
            _ -> call genExpression ops e
        A.ActualVariable am t v ->
          case t of
            A.Array _ _ ->
              do call genVariable ops v
                 tell [", "]
                 call genVariable ops v
                 tell ["_sizes"]
            _ -> fst $ abbrevVariable ops am t v

numCArgs :: [A.Actual] -> Int
numCArgs [] = 0
numCArgs (A.ActualVariable _ (A.Array _ _) _:fs) = 2 + numCArgs fs
numCArgs (A.ActualExpression (A.Array _ _) _:fs) = 2 + numCArgs fs
numCArgs (_:fs) = 1 + numCArgs fs

cgenFormals :: GenOps -> [A.Formal] -> CGen ()
cgenFormals ops fs = prefixComma (map (call genFormal ops) fs)

cgenFormal :: GenOps -> A.Formal -> CGen ()
cgenFormal ops (A.Formal am t n)
    = case t of
        A.Array _ t' ->
          do call genDecl ops am t n
             tell [", const int *"]
             genName n
             tell ["_sizes"]
        _ -> call genDecl ops am t n
--}}}

--{{{  processes
cgenProcess :: GenOps -> A.Process -> CGen ()
cgenProcess ops p = case p of
  A.Assign m vs es -> call genAssign ops m vs es
  A.Input m c im -> call genInput ops c im
  A.Output m c ois -> call genOutput ops c ois
  A.OutputCase m c t ois -> call genOutputCase ops c t ois
  A.Skip m -> tell ["/* skip */\n"]
  A.Stop m -> call genStop ops m "STOP process"
  A.Main m -> tell ["/* main */\n"]
  A.Seq _ s -> call genSeq ops s
  A.If m s -> call genIf ops m s
  A.Case m e s -> call genCase ops m e s
  A.While m e p -> call genWhile ops e p
  A.Par m pm s -> call genPar ops pm s
  -- PROCESSOR does nothing special.
  A.Processor m e p -> call genProcess ops p
  A.Alt m b s -> call genAlt ops b s
  A.ProcCall m n as -> call genProcCall ops n as
  A.IntrinsicProcCall m s as -> call genIntrinsicProc ops m s as

--{{{  assignment
cgenAssign :: GenOps -> Meta -> [A.Variable] -> A.ExpressionList -> CGen ()
cgenAssign ops m [v] el
    = case el of
        A.FunctionCallList _ _ _ -> call genMissing ops "function call"
        A.ExpressionList _ [e] ->
          do t <- typeOfVariable v
             doAssign t v e
  where
    doAssign :: A.Type -> A.Variable -> A.Expression -> CGen ()
    doAssign t v e
        = case call getScalarType ops t of
            Just _ ->
              do call genVariable ops v
                 tell [" = "]
                 call genExpression ops e
                 tell [";\n"]
            Nothing -> call genMissing ops $ "assignment of type " ++ show t
--}}}
--{{{  input
cgenInput :: GenOps -> A.Variable -> A.InputMode -> CGen ()
cgenInput ops c im
    =  do case im of
            A.InputTimerRead m (A.InVariable m' v) -> call genTimerRead ops c v
            A.InputTimerAfter m e -> call genTimerWait ops e
            A.InputSimple m is -> sequence_ $ map (call genInputItem ops c) is
            A.InputCase m s -> call genInputCase ops m c s
            _ -> call genMissing ops $ "genInput " ++ show im

cgenInputCase :: GenOps -> Meta -> A.Variable -> A.Structured -> CGen ()
cgenInputCase ops m c s
    =  do t <- typeOfVariable c
          let proto = case t of A.Chan _ _ (A.UserProtocol n) -> n
          tag <- makeNonce "case_tag"
          genName proto
          tell [" ", tag, ";\n"]
          tell ["ChanInInt ("]
          call genVariable ops c
          tell [", &", tag, ");\n"]
          tell ["switch (", tag, ") {\n"]
          genInputCaseBody proto c (return ()) s
          tell ["default:\n"]
          call genStop ops m "unhandled variant in CASE input"
          tell ["}\n"]
  where
    -- This handles specs in a slightly odd way, because we can't insert specs into
    -- the body of a switch.
    genInputCaseBody :: A.Name -> A.Variable -> CGen () -> A.Structured -> CGen ()
    genInputCaseBody proto c coll (A.Spec _ spec s)
        = genInputCaseBody proto c (call genSpec ops spec coll) s
    genInputCaseBody proto c coll (A.OnlyV _ (A.Variant _ n iis p))
        = do tell ["case "]
             genName n
             tell ["_"]
             genName proto
             tell [": {\n"]
             coll
             sequence_ $ map (call genInputItem ops c) iis
             call genProcess ops p
             tell ["break;\n"]
             tell ["}\n"]
    genInputCaseBody proto c coll (A.Several _ ss)
        = sequence_ $ map (genInputCaseBody proto c coll) ss

cgenTimerRead :: GenOps -> A.Variable -> A.Variable -> CGen ()
cgenTimerRead ops c v
    =  do tell ["ProcTime (&"]
          call genVariable ops c
          tell [");\n"]
          call genVariable ops v
          tell [" = "]
          call genVariable ops c
          tell [";\n"]

cgenTimerWait :: GenOps -> A.Expression -> CGen ()
cgenTimerWait ops e
    =  do tell ["ProcTimeAfter ("]
          call genExpression ops e
          tell [");\n"]
--}}}
--{{{  output
cgenOutput :: GenOps -> A.Variable -> [A.OutputItem] -> CGen ()
cgenOutput ops c ois = sequence_ $ map (call genOutputItem ops c) ois

cgenOutputCase :: GenOps -> A.Variable -> A.Name -> [A.OutputItem] -> CGen ()
cgenOutputCase ops c tag ois
    =  do t <- typeOfVariable c
          let proto = case t of A.Chan _ _ (A.UserProtocol n) -> n
          tell ["ChanOutInt ("]
          call genVariable ops c
          tell [", "]
          genName tag
          tell ["_"]
          genName proto
          tell [");\n"]
          call genOutput ops c ois
--}}}
--{{{  stop
cgenStop :: GenOps -> Meta -> String -> CGen ()
cgenStop ops m s
    =  do tell ["occam_stop ("]
          genMeta m
          tell [", \"", s, "\");\n"]
--}}}
--{{{  seq
cgenSeq :: GenOps -> A.Structured -> CGen ()
cgenSeq ops s = call genStructured ops s doP
  where
    doP (A.OnlyP _ p) = call genProcess ops p
--}}}
--{{{  if
cgenIf :: GenOps -> Meta -> A.Structured -> CGen ()
cgenIf ops m s
    =  do label <- makeNonce "if_end"
          genIfBody label s
          call genStop ops m "no choice matched in IF process"
          tell [label, ":\n;\n"]
  where
    genIfBody :: String -> A.Structured -> CGen ()
    genIfBody label s = call genStructured ops s doC
      where
        doC (A.OnlyC m (A.Choice m' e p))
            = do tell ["if ("]
                 call genExpression ops e
                 tell [") {\n"]
                 call genProcess ops p
                 tell ["goto ", label, ";\n"]
                 tell ["}\n"]
--}}}
--{{{  case
cgenCase :: GenOps -> Meta -> A.Expression -> A.Structured -> CGen ()
cgenCase ops m e s
    =  do tell ["switch ("]
          call genExpression ops e
          tell [") {\n"]
          seenDefault <- genCaseBody (return ()) s
          when (not seenDefault) $
            do tell ["default:\n"]
               call genStop ops m "no option matched in CASE process"
          tell ["}\n"]
  where
    -- FIXME -- can this be made common with genInputCaseBody above?
    genCaseBody :: CGen () -> A.Structured -> CGen Bool
    genCaseBody coll (A.Spec _ spec s)
        = genCaseBody (call genSpec ops spec coll) s
    genCaseBody coll (A.OnlyO _ (A.Option _ es p))
        =  do sequence_ [tell ["case "] >> call genExpression ops e >> tell [":\n"] | e <- es]
              tell ["{\n"]
              coll
              call genProcess ops p
              tell ["break;\n"]
              tell ["}\n"]
              return False
    genCaseBody coll (A.OnlyO _ (A.Else _ p))
        =  do tell ["default:\n"]
              tell ["{\n"]
              coll
              call genProcess ops p
              tell ["}\n"]
              return True
    genCaseBody coll (A.Several _ ss)
        =  do seens <- mapM (genCaseBody coll) ss
              return $ or seens
--}}}
--{{{  while
cgenWhile :: GenOps -> A.Expression -> A.Process -> CGen ()
cgenWhile ops e p
    =  do tell ["while ("]
          call genExpression ops e
          tell [") {\n"]
          call genProcess ops p
          tell ["}\n"]
--}}}
--{{{  par
cgenPar :: GenOps -> A.ParMode -> A.Structured -> CGen ()
cgenPar ops pm s
    =  do (size, _, _) <- constantFold $ addOne (sizeOfStructured s)
          pids <- makeNonce "pids"
          pris <- makeNonce "priorities"
          index <- makeNonce "i"
          when (pm == A.PriPar) $
            do tell ["int ", pris, "["]
               call genExpression ops size
               tell ["];\n"]
          tell ["Process *", pids, "["]
          call genExpression ops size
          tell ["];\n"]
          tell ["int ", index, " = 0;\n"]
          call genStructured ops s (createP pids pris index)
          tell [pids, "[", index, "] = NULL;\n"]
          case pm of
            A.PriPar -> tell ["ProcPriParList (", pids, ", ", pris, ");\n"]
            _ -> tell ["ProcParList (", pids, ");\n"]
          tell [index, " = 0;\n"]
          call genStructured ops s (freeP pids index)
  where
    createP pids pris index (A.OnlyP _ p)
        = do when (pm == A.PriPar) $
               tell [pris, "[", index, "] = ", index, ";\n"]
             tell [pids, "[", index, "++] = "]
             genProcAlloc p
             tell [";\n"]
    freeP pids index (A.OnlyP _ _)
        = do tell ["ProcAllocClean (", pids, "[", index, "++]);\n"]

    genProcAlloc :: A.Process -> CGen ()
    genProcAlloc (A.ProcCall m n as)
        =  do tell ["ProcAlloc ("]
              genName n
              let stackSize = nameString n ++ "_stack_size"
              tell [", ", stackSize, ", ", show $ numCArgs as]
              call genActuals ops as
              tell [")"]
    genProcAlloc p = call genMissing ops $ "genProcAlloc " ++ show p
--}}}
--{{{  alt
cgenAlt :: GenOps -> Bool -> A.Structured -> CGen ()
cgenAlt ops isPri s
    =  do tell ["AltStart ();\n"]
          tell ["{\n"]
          genAltEnable s
          tell ["}\n"]
          -- Like occ21, this is always a PRI ALT, so we can use it for both.
          tell ["AltWait ();\n"]
          id <- makeNonce "alt_id"
          tell ["int ", id, " = 0;\n"]
          tell ["{\n"]
          genAltDisable id s
          tell ["}\n"]
          fired <- makeNonce "alt_fired"
          tell ["int ", fired, " = AltEnd ();\n"]
          tell [id, " = 0;\n"]
          label <- makeNonce "alt_end"
          tell ["{\n"]
          genAltProcesses id fired label s
          tell ["}\n"]
          tell [label, ":\n;\n"]
  where
    genAltEnable :: A.Structured -> CGen ()
    genAltEnable s = call genStructured ops s doA
      where
        doA (A.OnlyA _ alt)
            = case alt of
                A.Alternative _ c im _ -> doIn c im
                A.AlternativeCond _ e c im _ -> withIf ops e $ doIn c im
                A.AlternativeSkip _ e _ -> withIf ops e $ tell ["AltEnableSkip ();\n"]

        doIn c im
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing ops "timer read in ALT"
                   A.InputTimerAfter _ time ->
                     do tell ["AltEnableTimer ("]
                        call genExpression ops time
                        tell [");\n"]
                   _ ->
                     do tell ["AltEnableChannel ("]
                        call genVariable ops c
                        tell [");\n"]

    genAltDisable :: String -> A.Structured -> CGen ()
    genAltDisable id s = call genStructured ops s doA
      where
        doA (A.OnlyA _ alt)
            = case alt of
                A.Alternative _ c im _ -> doIn c im
                A.AlternativeCond _ e c im _ -> withIf ops e $ doIn c im
                A.AlternativeSkip _ e _ -> withIf ops e $ tell ["AltDisableSkip (", id, "++);\n"]

        doIn c im
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing ops "timer read in ALT"
                   A.InputTimerAfter _ time ->
                     do tell ["AltDisableTimer (", id, "++, "]
                        call genExpression ops time
                        tell [");\n"]
                   _ ->
                     do tell ["AltDisableChannel (", id, "++, "]
                        call genVariable ops c
                        tell [");\n"]

    genAltProcesses :: String -> String -> String -> A.Structured -> CGen ()
    genAltProcesses id fired label s = call genStructured ops s doA
      where
        doA (A.OnlyA _ alt)
            = case alt of
                A.Alternative _ c im p -> doIn c im p
                A.AlternativeCond _ e c im p -> withIf ops e $ doIn c im p
                A.AlternativeSkip _ e p -> withIf ops e $ doCheck (call genProcess ops p)

        doIn c im p
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing ops "timer read in ALT"
                   A.InputTimerAfter _ _ -> doCheck (call genProcess ops p)
                   _ -> doCheck (call genInput ops c im >> call genProcess ops p)

        doCheck body
            = do tell ["if (", id, "++ == ", fired, ") {\n"]
                 body
                 tell ["goto ", label, ";\n"]
                 tell ["}\n"]

withIf :: GenOps -> A.Expression -> CGen () -> CGen ()
withIf ops cond body
    =  do tell ["if ("]
          call genExpression ops cond
          tell [") {\n"]
          body
          tell ["}\n"]
--}}}
--{{{  proc call
cgenProcCall :: GenOps -> A.Name -> [A.Actual] -> CGen ()
cgenProcCall ops n as
    =  do genName n
          tell [" (me"]
          call genActuals ops as
          tell [");\n"]
--}}}
--{{{  intrinsic procs
cgenIntrinsicProc :: GenOps -> Meta -> String -> [A.Actual] -> CGen ()
cgenIntrinsicProc ops m "ASSERT" [A.ActualExpression A.Bool e] = call genAssert ops m e
cgenIntrinsicProc ops _ s _ = call genMissing ops $ "intrinsic PROC " ++ s

cgenAssert :: GenOps -> Meta -> A.Expression -> CGen ()
cgenAssert ops m e
    =  do tell ["if (!"]
          call genExpression ops e
          tell [") {\n"]
          call genStop ops m "assertion failed"
          tell ["}\n"]
--}}}
--}}}
