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

module ParseRain where


import Control.Monad (liftM)
import Control.Monad.State (MonadState, liftIO, get, put)
import Data.Generics (Data)
import Data.List
import Data.Maybe
import qualified System.IO as IO
import Text.ParserCombinators.Parsec

import qualified AST as A
import CompState
import Errors
import Intrinsics
import qualified LexRain as L
import Metadata
import ParseUtils
import Pass
import Utils

type RainState = CompState
type RainParser = GenParser L.Token RainState

instance CSMR (GenParser tok CompState) where
  getCompState = getState

instance CSM (GenParser tok CompState) where
  putCompState = setState

instance Die (GenParser tok st) where
  dieReport (Just m, err) = fail $ packMeta m err
  dieReport (Nothing, err) = fail err  

sLeftQ, sRightQ, sLeftR, sRightR, sLeftC, sRightC, sSemiColon, sColon,
  sComma, sIn, sOut, sDots, sPar, sSeq, sAlt, sPri, sSeqeach, sPareach,
  sChannel, sOne2One, sIf, sElse, sWhile, sProcess, sFunction, sReturn,
  sWait, sFor, sUntil, sPoison :: RainParser Meta

--{{{ Symbols
sLeftQ = reserved "["
sRightQ = reserved "]"
sLeftR = reserved "("
sRightR = reserved ")"
sLeftC = reserved "{"
sRightC = reserved "}"
sSemiColon = reserved ";"
sColon = reserved ":"
sComma = reserved ","
sIn = reserved "?"
sOut = reserved "!"
sDots = reserved ".."
--}}}

--{{{ Keywords

sPar = reserved "par"
sSeq = reserved "seq"
sAlt = reserved "alt"
sPri = reserved "pri"
sSeqeach = reserved "seqeach"
sPareach = reserved "pareach"
sChannel = reserved "channel"
sOne2One = reserved "one2one"
sIf = reserved "if"
sElse = reserved "else"
sWhile = reserved "while"
sProcess = reserved "process"
sFunction = reserved "function"
sReturn = reserved "return"
sWait = reserved "wait"
sFor = reserved "for"
sUntil = reserved "until"
sPoison = reserved "poison"
--}}}

--{{{Operators

dyadicArithOp :: RainParser (Meta,A.Name)
dyadicArithOp
  = do {m <- reserved "+" ; return (m, A.Name m "+") }
    <|> do {m <- reserved "-" ; return (m, A.Name m "-") }
    <|> do {m <- reserved "*" ; return (m, A.Name m "*") }
    <|> do {m <- reserved "/" ; return (m, A.Name m "/") }
    <|> do {m <- reserved "%" ; return (m, A.Name m "%") }
    <|> do {m <- reserved "++" ; return (m, A.Name m "++") }

dyadicCompOp :: RainParser (Meta,A.Name)
dyadicCompOp
  = do {m <- reserved "<" ; return (m, A.Name m "<") }
    <|> do {m <- reserved ">" ; return (m, A.Name m ">") }
    <|> do {m <- reserved "<=" ; return (m, A.Name m "<=") }
    <|> do {m <- reserved ">=" ; return (m, A.Name m ">=") }
    <|> do {m <- reserved "==" ; return (m, A.Name m "=") }
    <|> do {m <- reserved "<>" ; return (m, A.Name m "<>") }

-- TODO remove this in future, I think
monadicArithOp :: RainParser (Meta,A.Name)
monadicArithOp
  = do {m <- reserved "-" ; return (m, A.Name m "-") }



--}}}

getToken :: (L.TokenType -> Maybe x) -> RainParser (Meta, x)
getToken test = token (show) (metaToSourcePos . fst) (wrap test)
  where
    wrap :: (L.TokenType -> Maybe x) -> (Meta,L.TokenType) -> Maybe (Meta,x)
    wrap f (m,t) = case f t of
      Nothing -> Nothing
      Just t' -> Just (m,t')

identifier :: RainParser (Meta, String)
identifier = getToken testToken
  where
    testToken (L.TokIdentifier id) = Just id
    testToken _ = Nothing

reserved :: String -> RainParser Meta
reserved word 
  = (liftM fst) (getToken testToken)
    <?> ("reserved word: " ++ word)
      where
        testToken (L.TokReserved r) = if r == word then Just r else Nothing
        testToken _ = Nothing


name :: RainParser A.Name
name 
    =   do (m,s) <- identifier
           return $ A.Name m s
    <?> "name"


dataType :: RainParser A.Type
dataType 
  = do {reserved "bool" ; return A.Bool}
    <|> do {reserved "int" ; return A.Int}
    <|> do {reserved "uint8" ; return A.Byte}
    <|> do {reserved "uint16" ; return A.UInt16}
    <|> do {reserved "uint32" ; return A.UInt32}
    <|> do {reserved "uint64" ; return A.UInt64}
    <|> do {reserved "sint8" ; return A.Int8}
    <|> do {reserved "sint16" ; return A.Int16}
    <|> do {reserved "sint32" ; return A.Int32}
    <|> do {reserved "sint64" ; return A.Int64}    
    <|> do {reserved "time" ; return A.Time}
    <|> do {sChannel ; inner <- dataType ; return $ A.Chan (A.ChanAttributes {A.caWritingShared = A.Unshared, A.caReadingShared = A.Unshared}) inner}
    <|> do {sIn ; inner <- dataType ; return $ A.ChanEnd A.DirInput A.Unshared inner}
    <|> do {sOut ; inner <- dataType ; return $ A.ChanEnd A.DirOutput A.Unshared inner}
    <|> do {sLeftQ ; inner <- dataType ; sRightQ ; return $ A.List inner}
    <|> do {(m,n) <- identifier ; return $ A.UserDataType A.Name {A.nameMeta = m, A.nameName = n}}
    <?> "data type"

variable :: RainParser A.Variable
variable = do {v <- name ; return $ A.Variable (A.nameMeta v) v}
             <|> try (do {m <- sIn ; v <- variable ; return $ A.DirectedVariable m A.DirInput v})
             <|> try (do {m <- sOut ; v <- variable ; return $ A.DirectedVariable m A.DirOutput v})
             <?> "variable"

lvalue :: RainParser A.Variable
lvalue = variable

stringLiteral :: RainParser A.LiteralRepr
stringLiteral
    =  do (m,str) <- getToken testToken
          let processed = replaceEscapes str
              aes = A.Several m [A.Only m $ A.Literal m A.Byte $ A.ByteLiteral m [c] | c <- processed]
          return (A.ArrayListLiteral m aes)
    <?> "string literal"
  where
    testToken (L.TokStringLiteral str) = Just str
    testToken _ = Nothing

replaceEscapes :: String -> String
replaceEscapes [] = []
replaceEscapes ('\\':(c:cs)) = if c == 'n' then ('\n':replaceEscapes cs) else (c:replaceEscapes cs)
replaceEscapes (c:cs) = (c:replaceEscapes cs)

literalCharacter :: RainParser A.LiteralRepr
literalCharacter
    =   do (m,c) <- getToken testToken
           return $ A.ByteLiteral m (replaceEscapes c)
  where
    testToken (L.TokCharLiteral c) = Just c
    testToken _ = Nothing
           
integer :: RainParser (Integer, A.LiteralRepr)
integer
    =  do (m,d) <- getToken testToken
          return $ (read d, A.IntLiteral m d)
  where
    testToken (L.TokDecimalLiteral d) = Just d
    testToken _ = Nothing

integerLiteral :: RainParser A.Expression
integerLiteral = do (val, i) <- integer
                    u <- getUniqueIdentifer
                    let m = findMeta i
                    return $ A.Literal m (A.UnknownNumLitType m u val) i

listLiteral :: RainParser A.Expression
listLiteral
  = try $ do m <- sLeftQ
             u <- getUniqueIdentifer
             let t = A.List $ A.UnknownVarType (A.TypeRequirements False) (Right (m,u))
             (do try sRightQ
                 return $ A.Literal m t $ A.ArrayListLiteral m (A.Several m [])
              <|> do e0 <- try expression
                     (do try sRightQ
                         return $ A.Literal m t $ A.ArrayListLiteral m $
                           A.Several m [A.Only m e0]
                      -- Up until the first comma, this may be a type declaration
                      -- in a cast expression, so we "try" all the way
                      -- up until that comma
                      <|> do try sComma
                             es <- sepBy1 expression sComma
                             sRightQ
                             return $ A.Literal m t $
                               A.ArrayListLiteral m $ A.Several m $
                                 map (A.Only m) (e0 : es)
                      )
              )

literal :: RainParser A.Expression
literal = do {lr <- stringLiteral ; return $ A.Literal (findMeta lr) (A.List A.Byte) lr }
          <|> do {c <- literalCharacter ; return $ A.Literal (findMeta c) A.Byte c}
          <|> integerLiteral
          <|> do {m <- reserved "true" ; return $ A.True m}
          <|> do {m <- reserved "false" ; return $ A.False m}
          <|> listLiteral
          <?> "literal"

maybeParse :: RainParser a -> RainParser (Maybe a)
maybeParse p = option Nothing (p >>* Just)

range :: RainParser A.Expression
range = try $ do m <- sLeftQ
                 optTy <- maybeParse $ try $ do t <- dataType
                                                m <- sColon
                                                return (t, m)
                 begin <- literal
                 sDots
                 end <- literal
                 sRightQ
                 (t, be) <- case optTy of
                   Just (t, mc) ->
                     let begin' = A.Conversion mc A.DefaultConversion t begin
                         end' = A.Conversion mc A.DefaultConversion t end
                     in return (A.List t, (begin', end'))
                   Nothing -> do u <- getUniqueIdentifer
                                 let t = A.List $ A.UnknownVarType (A.TypeRequirements
                                          False) (Right (m,u))
                                 return (t, (begin, end))
                 return $ A.Literal m t $ A.RangeLiteral m (fst be) (snd be)

expression :: RainParser A.Expression
expression
  = try compExpression
    <|> try castExpression
    <|> try subExpression
    <?> "expression"
  where
    castExpression :: RainParser A.Expression
    castExpression = (try $ do {ty <- dataType ; m <- sColon ; e <- expression ; return $ A.Conversion m A.DefaultConversion ty e})

    compExpression :: RainParser A.Expression
    compExpression = do {lhs <- subExpression ; (m,op) <- dyadicCompOp ; rhs <- subExpression ; return $ A.FunctionCall m op [lhs, rhs] }

    subExpression :: RainParser A.Expression
    subExpression
      = do se <- subExpr'
           further <- many (do {(m, op) <- dyadicArithOp ; exp <- subExpr' ; return (m,op,exp)})
           --further :: [(Meta,A.DyadicOp,A.Expression)]
           return $ foldl foldOps se further

    foldOps :: A.Expression -> (Meta,A.Name,A.Expression) -> A.Expression
    foldOps lhs (m,op,rhs) = A.FunctionCall m op [lhs, rhs]

    subExpr' :: RainParser A.Expression
    subExpr' = try functionCall
               <|> do {id <- variable ; return $ A.ExprVariable (findMeta id) id}
               <|> literal
               <|> range
               <|> do {(m,op) <- monadicArithOp ; rhs <- subExpr' ; return $ A.FunctionCall m op [rhs]}
               <|> do {sLeftR ; e <- expression ; sRightR ; return e}

functionCall :: RainParser A.Expression
functionCall =  do funcName <- name
                   sLeftR
                   es <- sepBy expression sComma
                   sRightR
                   case lookup (A.nameName funcName) rainIntrinsicFunctions of
                     Just _ -> return $ A.IntrinsicFunctionCall (A.nameMeta
                       funcName) (A.nameName funcName) es
                     Nothing -> return $
                       A.FunctionCall (A.nameMeta funcName) funcName es

data InnerBlockLineState = Decls | NoMoreDecls | Mixed deriving (Eq)


innerBlock :: Bool -> Maybe A.Name -> RainParser (A.Structured A.Process)
innerBlock declsMustBeFirst funcName
                            = do m <- sLeftC 
                                 lines <- linesToEnd (if declsMustBeFirst then Decls else Mixed)
                                 case lines of
                                   Left single -> return single
                                   Right lines -> return $ A.Several m lines
  where
    wrapProc :: A.Process -> A.Structured A.Process
    wrapProc x = A.Only (findMeta x) x
        
    makeList :: Either (A.Structured A.Process) [A.Structured A.Process] -> [A.Structured A.Process]
    makeList (Left s) = [s]
    makeList (Right ss) = ss
        
    --Returns either a single line (which means the immediate next line is a declaration) or a list of remaining lines
    linesToEnd :: InnerBlockLineState -> RainParser (Either (A.Structured A.Process) [A.Structured A.Process])
    linesToEnd state
               = (if state /= NoMoreDecls then 
                    do (m,decl) <- declaration 
                       rest <- linesToEnd state 
                       case rest of 
                         Left s -> return $ Left $ decl s
                         Right ss -> return $ Left $ decl $ A.Several m ss 
                  else pzero)
                 <|> do {st <- statement ; rest <- linesToEnd nextState ; return $ Right $ (wrapProc st) : (makeList rest)}
                 --Although return is technically a statement, we parse it here because it can only occur inside the right kind of block:
                 <|> (case funcName of
                        Nothing -> pzero
                        Just actFuncName ->
                          do m <- sReturn
                             exp <- expression
                             sSemiColon
                             rest <- linesToEnd nextState
                             return $ Right $ (A.Only m $ A.Assign m [A.Variable m actFuncName] $ A.ExpressionList (findMeta exp) [exp]) : (makeList rest)
                     )
                 <|> do {sRightC ; return $ Right []}
                 <?> "statement, declaration, or end of block"
                 where
                   nextState = if state == Mixed then Mixed else NoMoreDecls

block :: RainParser A.Process
block = do { optionalSeq ; b <- innerBlock False Nothing ; return $ A.Seq (findMeta b) b}
        <|> do { m <- sPar ; b <- innerBlock True Nothing ; return $ A.Par m A.PlainPar b}
        <?> "seq or par block"

optionalSeq :: RainParser ()
optionalSeq = option () (sSeq >> return ())

assignOp :: RainParser (Meta, Maybe A.Name)
--consume an optional operator, then an equals sign (so we can handle = += /= etc)  This should not handle !=, nor crazy things like ===, <== (nor <=)
assignOp
  = do {m <- reserved "+=" ; return (m,Just $ A.Name m  "+")}
    <|> do {m <- reserved "-=" ; return (m,Just $ A.Name m  "-")}
    <|> do {m <- reserved "*=" ; return (m,Just $ A.Name m  "*")}
    <|> do {m <- reserved "/=" ; return (m,Just $ A.Name m  "/")}
    <|> do {m <- reserved "%=" ; return (m,Just $ A.Name m  "%")}
    <|> do {m <- reserved "=" ; return (m,Nothing)}


each :: RainParser A.Process
each = do { m <- sPareach ; sLeftR ; n <- name ; sColon ; exp <- expression ; sRightR ; st <- block ; 
             return $ A.Par m A.PlainPar $ A.Spec m (A.Specification m n $
                A.Rep m (A.ForEach m exp)) $ A.Only m st }
       <|> do { m <- sSeqeach ; sLeftR ; n <- name ; sColon ; exp <- expression ; sRightR ; st <- block ; 
             return $ A.Seq m $ A.Spec m (A.Specification m n $ A.Rep m (A.ForEach m exp)) $ A.Only m st }

comm :: Bool -> RainParser A.Process
comm isAlt
     = do { lv <- lvalue ; 
              (if isAlt
                then pzero
                else do {sOut ; exp <- expression ; possSemiColon ; return $ A.Output (findMeta lv) lv [A.OutExpression (findMeta exp) exp] })
              <|> do {sIn ; rv <- lvalue ; possSemiColon ; return $ A.Input (findMeta lv) lv $ A.InputSimple (findMeta rv) [A.InVariable (findMeta rv) rv] Nothing }
              <?> (if isAlt then "input statement" else "input or output statement")
          }
       where
         possSemiColon :: RainParser ()
         possSemiColon = if isAlt then return () else sSemiColon >> return ()

alt :: RainParser A.Process
alt = do {m <- sPri ; sAlt ; m' <- sLeftC ; cases <- many altCase ; optElseCase <- option [] (singleton elseCase) ; sRightC ; return $ A.Alt m True $ A.Several m' (cases ++ optElseCase)}
  where
    singleton :: RainParser a -> RainParser [a]
    singleton p = do {a <- p ; return [a]}
  
    altCase :: RainParser (A.Structured A.Alternative)
    altCase = do input <- comm True
                 case input of
                   A.Input m lv im -> do body <- block
                                         return $ A.Only m $ A.Alternative m
                                           (A.True m) lv im body
                   _ -> dieP (findMeta input) $ "communication type not supported in an alt: \"" ++ show input ++ "\""
              <|> do (m, wm) <- waitStatement True
                     body <- block
                     return $ A.Only m $ A.Alternative m (A.True m)
                       (A.Variable m rainTimerName) wm body
    elseCase :: RainParser (A.Structured A.Alternative)
    elseCase = do m <- sElse
                  body <- block
                  return $ A.Only m $ A.AlternativeSkip m (A.True m) body

tuple :: RainParser [A.Expression]
tuple = do { sLeftR ; items <- expression `sepBy` sComma ; sRightR ; return items }

runProcess :: RainParser A.Process
runProcess = do (mProcess,processName) <- identifier
                items <- tuple
                sSemiColon
                return $ A.ProcCall mProcess A.Name {A.nameName = processName, A.nameMeta = mProcess} (map convertItem items)
  where
    convertItem :: A.Expression -> A.Actual
    convertItem (A.ExprVariable _ v) = A.ActualVariable v
    convertItem e = A.ActualExpression e

waitStatement :: Bool -> RainParser (Meta, A.InputMode)
waitStatement isAlt
  = do { m <- sWait ;
         do { sFor ; e <- expression ; possSemiColon ;
              return (m, A.InputTimerFor m e)}
         <|> do { sUntil ; e <- expression ; possSemiColon ;
                  return (m, A.InputTimerAfter m e)}
         <?> "reserved word \"for\" or \"until\" should follow reserved word \"wait\""
       }
    where
      possSemiColon :: RainParser ()
      possSemiColon = if isAlt then return () else sSemiColon >> return ()

statement :: RainParser A.Process
statement 
  = do { m <- sWhile ; sLeftR ; exp <- expression ; sRightR ; st <- block ; return $ A.While m exp st}
    <|> do { m <- sIf ; sLeftR ; exp <- expression ; sRightR ; st <- block ; 
             option (A.If m $ A.Several m [A.Only m (A.Choice m exp st), A.Only m (A.Choice m (A.True m) (A.Skip m))])
                    (do {sElse ; elSt <- block ; return (A.If m $ A.Several m [A.Only m (A.Choice m exp st), A.Only m (A.Choice m (A.True m) elSt)])})
           }
    <|> block
    <|> each
    <|> try runProcess
    <|> do {m <- reserved "now" ; dest <- lvalue ; sSemiColon ; return $ A.Input
      m (A.Variable m rainTimerName) $ A.InputTimerRead m $ A.InVariable m dest}
    <|> do {(m,wm) <- waitStatement False; return $ A.Input m (A.Variable m
      rainTimerName) wm}
    <|> try (comm False)
    <|> alt
    <|> do {m <- sPoison ; ch <- lvalue; sSemiColon ; return $ A.InjectPoison m ch}
    <|> try (do { lv <- lvalue ; op <- assignOp ; exp <- expression ; sSemiColon ; 
             case op of 
               (m', Just dyOp) -> return (A.Assign m' [lv] (A.ExpressionList m' [(A.FunctionCall m' dyOp [A.ExprVariable (findMeta lv) lv, exp])]))
               (m', Nothing) -> return (A.Assign m' [lv] (A.ExpressionList (findMeta exp) [exp]))
           })   
    <?> "statement"

formaliseTuple :: [(A.Name,A.Type)] -> [A.Formal]
formaliseTuple = map (\(n,t) -> A.Formal A.ValAbbrev t n)

tupleDef :: RainParser [(A.Name,A.Type)]
tupleDef = do {sLeftR ; tm <- sepBy tupleDefMember sComma ; sRightR ; return tm}
  where
    tupleDefMember :: RainParser (A.Name,A.Type)
    tupleDefMember = do {t <- dataType ; sColon ; n <- name ; return (n,t)}

declaration :: Data a => RainParser (Meta, A.Structured a -> A.Structured a)
declaration = try $ do {t <- dataType; m <- sColon ; ns <- name `sepBy1` sComma ; sSemiColon ; 
                          return (m, \x -> foldr (foldSpec t) x ns) }
  where
    foldSpec :: Data a => A.Type -> A.Name -> (A.Structured a -> A.Structured a)
    foldSpec t n = A.Spec (A.nameMeta n) $ A.Specification (A.nameMeta n) n $ A.Declaration (A.nameMeta n) t

terminator :: Data a => A.Structured a
terminator = A.Several emptyMeta []

processDecl :: RainParser A.AST
processDecl = do {m <- sProcess ; procName <- name ; params <- tupleDef ; body <- block ;
  return $ A.Spec m
    (A.Specification m procName (A.Proc m (A.PlainSpec, A.Recursive) (formaliseTuple params) $ Just body))
  terminator}

functionDecl :: RainParser A.AST
functionDecl = do {m <- sFunction ; retType <- dataType ; sColon ; funcName <- name ; params <- tupleDef ; body <- innerBlock False (Just funcName) ;
  return $ A.Spec m
    (A.Specification m funcName (A.Function m (A.PlainSpec, A.Recursive) [retType] (formaliseTuple params) (Just $ Right $ A.Seq m body)))
    terminator}

topLevelDecl :: RainParser A.AST
topLevelDecl = do decls <- many (processDecl <|> functionDecl <?> "process or function declaration")
                  eof
                  return $ A.Several emptyMeta decls

rainSourceFile :: RainParser (A.AST, CompState)
rainSourceFile
    =   do p <- topLevelDecl
           s <- getState
           return (p, s)

-- | A ghost variable for Rain's single timer.
-- This is used for all timer operations.
rainTimerName :: A.Name
rainTimerName = A.Name emptyMeta "rain_timer"

rainTimerNameDef :: A.NameDef
rainTimerNameDef
    = A.NameDef { A.ndMeta = emptyMeta
                , A.ndName = A.nameName rainTimerName
                , A.ndOrigName = A.nameName rainTimerName
                , A.ndSpecType = A.Declaration emptyMeta (A.Timer A.RainTimer)
                , A.ndAbbrevMode = A.Original
                , A.ndNameSource = A.NamePredefined
                , A.ndPlacement = A.Unplaced
                }

-- | Parse Rain source text (with filename for error messages)
parseRainProgram :: FilePath -> String -> PassM A.AST
parseRainProgram filename source
    =  do lexOut <- liftIO $ L.runLexer filename source
          case lexOut of
            Left merr -> dieP merr $ "Parse (lexing) error"
            Right toks ->
              do defineName rainTimerName rainTimerNameDef
                 cs <- get
                 case runParser rainSourceFile cs filename toks of
                   Left err -> dieP (sourcePosToMeta $ errorPos err) $ "Parse error: " ++ show err
                   Right (p, cs') ->
                     do put cs'
                        return p
