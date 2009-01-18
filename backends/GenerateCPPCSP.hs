{-
Tock: a compiler for parallel languages
Copyright (C) 2007, 2008  University of Kent

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

{-| Generate C++ code from the mangled AST that uses the C++CSP2 library.
In order to compile the generated code, you will need:

* A standards-compliant C++98 compiler (GCC or Visual Studio >= 2003, but not Visual Studio 6).
 
* The C++CSP2 library (>= 2.0.2), available from <http://www.cppcsp.net/>, and any appropriate dependencies (e.g. Boost).

Channels of direction 'A.DirUnknown' are passed around as pointers to a One2OneChannel\<\> object.  To read I use the reader() function and to write I use the writer() function.
For channels of direction 'A.DirInput' or 'A.DirOutput' I actually pass the Chanin\<\> and Chanout\<\> objects as you would expect.
-}
module GenerateCPPCSP (cppcspPrereq, cppgenOps, generateCPPCSP, genCPPCSPPasses) where

import Control.Monad.State
import Data.Char
import Data.Generics
import Data.List
import Data.Maybe
import System.IO

import qualified AST as A
import CompState
import GenerateC (cgenOps, cgenReplicatorLoop, cgenType, cintroduceSpec, cremoveSpec,
  generate, genComma, genLeftB, genMeta, genName, genRightB, justOnly, seqComma, withIf)
import GenerateCBased
import Metadata
import Pass
import qualified Properties as Prop
import ShowCode
import TLP
import Traversal
import Types
import TypeSizes
import Utils

--{{{  generator ops
-- | Operations for the C++CSP backend.
-- Most of this is inherited directly from the C backend in the "GenerateC" module.
cppgenOps :: GenOps
cppgenOps = cgenOps {
    declareFree = cppdeclareFree,
    declareInit = cppdeclareInit,
    genActuals = cppgenActuals,
    genAllocMobile = cppgenAllocMobile,
    genAlt = cppgenAlt,
    genClearMobile = cppgenClearMobile,
    genDirectedVariable = cppgenDirectedVariable,
    genForwardDeclaration = cppgenForwardDeclaration,
    genGetTime = cppgenGetTime,
    genIf = cppgenIf,
    genInputItem = cppgenInputItem,
    genListAssign = cppgenListAssign,
    genListConcat = cppgenListConcat,
    genListSize = cppgenListSize,
    genListLiteral = cppgenListLiteral,
    genOutputCase = cppgenOutputCase,
    genOutputItem = cppgenOutputItem,
    genPar = cppgenPar,
    genPoison = cppgenPoison,
    genProcCall = cppgenProcCall,
    genReplicatorLoop = cppgenReplicatorLoop,
    genStop = cppgenStop,
    genTimerRead = cppgenTimerRead,
    genTimerWait = cppgenTimerWait,
    genTopLevel = cppgenTopLevel,
    genType = cppgenType,
    genUnfoldedExpression = cppgenUnfoldedExpression,
    genUnfoldedVariable = cppgenUnfoldedVariable,
    getScalarType = cppgetScalarType,
    introduceSpec = cppintroduceSpec,
    removeSpec = cppremoveSpec
  }
--}}}

genCPPCSPPasses :: [Pass]
genCPPCSPPasses = [chansToAny]

chansToAny :: Pass
chansToAny = cppOnlyPass "Transform channels to ANY"
  [Prop.processTypesChecked]
  [Prop.allChansToAnyOrProtocol]
  $      \x -> do st <- get
                  case csFrontend st of
                    FrontendOccam ->
                      do chansToAnyInCompState
                         chansToAnyM x
                    _ -> return x
  where
    chansToAny' :: A.Type -> PassM A.Type
    chansToAny' c@(A.Chan _ _ (A.UserProtocol {})) = return c
    chansToAny' (A.Chan a b _) = return $ A.Chan a b A.Any
    chansToAny' t = return t
    
    chansToAnyM :: Data t => t -> PassM t
    chansToAnyM = applyDepthM chansToAny'
    
    chansToAnyInCompState :: PassM ()
    chansToAnyInCompState = do st <- get
                               csn <- chansToAnyM (csNames st)
                               put $ st {csNames = csn}
                               return ()

--{{{  top-level
-- | Transforms the given AST into a pass that generates C++ code.
generateCPPCSP :: Handle -> A.AST -> PassM ()
generateCPPCSP = generate cppgenOps

cppcspPrereq :: [Property]
cppcspPrereq = cCppCommonPreReq ++ [Prop.allChansToAnyOrProtocol]
 

-- | Generates the top-level code for an AST.
cppgenTopLevel :: A.AST -> CGen ()
cppgenTopLevel s
    =  do tell ["#include <tock_support_cppcsp.h>\n"]
          --In future, these declarations could be moved to a header file:
          sequence_ $ map (call genForwardDeclaration) (listify (const True :: A.Specification -> Bool) s)
          call genStructured s (\m _ -> tell ["\n#error Invalid top-level item: ",show m])
          (name, chans) <- tlpInterface
          tell ["int main (int argc, char** argv) { csp::Start_CPPCSP();"]
          (chanTypeRead, chanTypeWrite, writer, reader) <- 
                      do st <- getCompState
                         case csFrontend st of
                           FrontendOccam -> return ("tockSendableArrayOfBytes",
                                                    "tockSendableArrayOfBytes",
                                                    "StreamWriterByteArray",
                                                    "StreamReaderByteArray")
                           _ -> return ("uint8_t", "tockList<uint8_t>/**/","StreamWriterList", "StreamReader")
          
          tell ["csp::One2OneChannel<",chanTypeRead,"> in;"]
          tell ["csp::One2OneChannel<",chanTypeWrite,"> out,err;"]
          tell [" csp::Run( csp::InParallel ",
                "(new ",writer,"(std::cout,out.reader())) ",
                "(new ",writer,"(std::cerr,err.reader())) ",
                "(new ",reader,"(std::cin,in.writer())) ",
                "(csp::InSequenceOneThread ( new proc_"]
          genName name 
          tell ["("]
          infixComma $ map tlpChannel chans
          tell [")) (new LethalProcess()) ) );",
                "csp::End_CPPCSP(); return 0;}\n"]
  where
    tlpChannel :: (A.Direction,TLPChannel) -> CGen()
    tlpChannel (dir,c) = case dir of
                               A.DirUnknown -> tell ["&", chanName]
                               A.DirInput -> tell [chanName, ".reader() "]
                               A.DirOutput -> tell [chanName, ".writer() "]
                             where
                               chanName = case c of
                                            TLPIn -> "in"
                                            TLPOut -> "out"
                                            TLPError -> "err"

--}}}


-- | CIF has a stop function for stopping processes.
--In C++CSP I use the exception handling to make a stop call throw a StopException,
--and the catch is placed so that catching a stop exception immediately finishes the process
cppgenStop :: Meta -> String -> CGen ()
cppgenStop m s 
  = do tell ["throw StopException("]
       genMeta m
       tell [" \"",s,"\");"]

--{{{ Two helper functions to aggregate some common functionality in this file.

-- | Generates code from a channel 'A.Variable' that will be of type Chanin\<\>
genCPPCSPChannelInput :: A.Variable -> CGen()
genCPPCSPChannelInput var
  = do t <- astTypeOf var
       case t of
         (A.Chan A.DirInput _ _) -> call genVariable var
         (A.Chan A.DirUnknown _ _) -> do call genVariable var
                                         tell ["->reader()"]
         _ -> call genMissing $ "genCPPCSPChannelInput used on something which does not support input: " ++ show var

-- | Generates code from a channel 'A.Variable' that will be of type Chanout\<\>
genCPPCSPChannelOutput :: A.Variable -> CGen()
genCPPCSPChannelOutput var
  = do t <- astTypeOf var
       case t of
         (A.Chan A.DirOutput _ _) -> call genVariable var
         (A.Chan A.DirUnknown _ _) -> do call genVariable var
                                         tell ["->writer()"]
         _ -> call genMissing $ "genCPPCSPChannelOutput used on something which does not support output: " ++ show var

cppgenPoison :: Meta -> A.Variable -> CGen ()
cppgenPoison _m var
  = do call genVariable var
       tell ["->poison();"]
--}}}

-- | C++CSP2 returns the number of seconds since the epoch as the time
--Since this is too large to be contained in an int once it has been multiplied,
--the remainder is taken to trim the timer back down to something that will be useful in an int
cppgenTimerRead :: A.Variable -> A.Variable -> CGen ()
cppgenTimerRead c v = do
   tt <- astTypeOf c
   case tt of
     A.Timer A.RainTimer ->
       do tell ["csp::CurrentTime (&"]
          call genVariable v
          tell [");"]
     A.Timer A.OccamTimer ->
       do tell ["csp::CurrentTime (&"]
          call genVariable c
          tell [");\n"]
          call genVariable v
          tell [" = (int)(unsigned)remainder(1000000.0 * csp::GetSeconds("]
          call genVariable c
          tell ["),4294967296.0);"]
     _ -> call genMissing $ "Unsupported timer type: " ++ show tt

cppgenGetTime :: A.Variable -> CGen ()
cppgenGetTime v
    =  do tell ["csp::CurrentTime(&"]
          call genVariable v
          tell [");"]

{-|
Gets a csp::Time to wait with, given a 32-bit microsecond value (returns the temp variable we have put it in)


Time in occam is in microseconds, and is usually stored in the user's programs as a signed 32-bit integer.  Therefore the timer wraps round 
approx every 72 minutes.  A usual pattern of behaviour might be: 

      TIMER tim:
      INT t:
      SEQ
        tim ? t                 -- read current time
        t := t PLUS us          -- add delay
        tim ? AFTER t           -- wait until time "t"

According to Fred's occam page that I took that from, half of time delays are considered in the past and the other half are considered in the future.

Now consider C++CSP's time.  It typically has a more expressive time - on Linux, time is measured since the epoch.  Since the epoch was more 
than 72 minutes ago, this is problematic when converted to microseconds and stuffed into a 32-bit int.  I'll express C++CSP times as (HIGH, LOW) 
where LOW is the lowest 32 bits, and HIGH is the higher bits.

Getting the time for the occam programmer is quite straightforward - we retrieve the C++CSP time, and hand LOW back to the programmer as 
a 32-bit signed value (LOW is unsigned normally).

The occam programmer will now add some delay to their LOW value, making it LOWalpha.  They then ask to wait until LOWalpha.  We know that 
LOWalpha came from LOW at some point in the past and has been added to.  We need to combine it with some HIGH value, HIGHalpha to form 
(HIGHalpha, LOWalpha), the time to wait until.  So what should HIGHalpha be?

We could say that HIGHalpha = HIGH.  But if the user wrapped around LOWalpha, we actually want: HIGHalpha = HIGH + 1.  So we need to check 
if LOWalpha is a wrapped round version of LOW.  This could be done by checking whether LOWalpha < LOW.  If this is true, it must have wrapped.  
Otherwise, it must not have.
-}
genCPPCSPTime :: A.Expression -> CGen String
genCPPCSPTime e
    = do  time <- csmLift $ makeNonce "time_exp"
          tell ["unsigned ",time," = (unsigned)"]
          call genExpression e
          tell [" ; "]
          curTime <- csmLift $ makeNonce "time_exp"
          curTimeLow <- csmLift $ makeNonce "time_exp"
          curTimeHigh <- csmLift $ makeNonce "time_exp"
          retTime <- csmLift $ makeNonce "time_exp"
          tell ["double ",curTime," = csp::GetSeconds(csp::CurrentTime());"]
          tell ["unsigned ",curTimeLow," = (unsigned)remainder(1000000.0 * ",curTime,",4294967296.0);"]
          tell ["unsigned ",curTimeHigh," = (unsigned)((1000000.0 * ",curTime,") / 4294967296.0);"]
          --if time is less than curTime, it must have wrapped around so add one:
          tell ["csp::Time ",retTime," = csp::Seconds((((double)(",curTimeHigh," + TimeDiffHelper(",curTimeLow,",",time,")) * 4294967296.0) + (double)",time,") / 1000000.0);"]
          return retTime

cppgenTimerWait :: A.Expression -> CGen ()
cppgenTimerWait e
    =  do 
          time <- genCPPCSPTime e
          tell ["csp::SleepUntil(",time,");"]

cppgenInputItem :: A.Variable -> A.InputItem -> CGen ()
cppgenInputItem c dest
  = case dest of
      (A.InCounted m cv av) -> 
        do call genInputItem c (A.InVariable m cv)
           recvBytes av (
             do call genVariable cv
                tell ["*"]
                t <- astTypeOf av
                subT <- trivialSubscriptType m t
                call genBytesIn m subT (Right av)
             )
      (A.InVariable m v) ->
        do ct <- astTypeOf c
           t <- astTypeOf v
           recvBytes v (call genBytesIn m t (Right v))
  where
    chan' = genCPPCSPChannelInput c
    recvBytes :: A.Variable -> CGen () -> CGen ()
    recvBytes v b = do tell ["tockRecvArrayOfBytes("]
                       chan'
                       tell [",tockSendableArrayOfBytes("]
                       b
                       tell [","]
                       genPoint v
                       tell ["));"]

cppgenOutputItem :: A.Variable -> A.OutputItem -> CGen ()
cppgenOutputItem chan item
  = case item of
      (A.OutCounted m (A.ExprVariable _ cv) (A.ExprVariable _ av)) -> (sendBytes cv) >> (sendBytes av)
      (A.OutExpression _ (A.ExprVariable _ sv)) ->
       do t <- astTypeOf chan
          tsv <- astTypeOf sv
          sendBytes sv
  where
    chan' = genCPPCSPChannelOutput chan
    
    sendBytes v = do tell ["tockSendArrayOfBytes("]
                     chan'
                     tell [",tockSendableArrayOfBytes("]
                     genPoint v
                     tell ["));"]

byteArrayChan :: A.Type -> Bool
byteArrayChan (A.Chan _ _ (A.UserProtocol _)) = True
byteArrayChan (A.Chan _ _ A.Any) = True
byteArrayChan (A.Chan _ _ (A.Counted _ _)) = True
byteArrayChan _ = False

genPoint :: A.Variable -> CGen()
genPoint v = do t <- astTypeOf v
                when (not $ isPoint t) $ tell ["&"]
                call genVariable v
genNonPoint :: A.Variable -> CGen()
genNonPoint v = do t <- astTypeOf v
                   when (isPoint t) $ tell ["*"]
                   call genVariable v                    
isPoint :: A.Type -> Bool
isPoint (A.Record _) = True
isPoint (A.Array _ _) = True
isPoint _ = False

-- FIXME Should be a generic helper somewhere (along with the others from GenerateC)
-- | Helper function to place a comma between items, but not before or after
infixComma :: [CGen ()] -> CGen ()
infixComma (c0:cs) = c0 >> sequence_ [genComma >> c | c <- cs]
infixComma [] = return ()

cppgenOutputCase :: A.Variable -> A.Name -> [A.OutputItem] -> CGen ()
cppgenOutputCase c tag ois 
    =  do t <- astTypeOf c
          let proto = case t of A.Chan _ _ (A.UserProtocol n) -> n
          tell ["tockSendInt("]
          genCPPCSPChannelOutput c
          tell [","]
          genName tag
          tell ["_"]
          genName proto
          tell [");"]
          call genOutput c ois


-- | We use the process wrappers here, in order to execute the functions in parallel.
--We use forking instead of Run\/InParallelOneThread, because it is easier to use forking with replication.
cppgenPar :: A.ParMode -> A.Structured A.Process -> CGen ()
cppgenPar _ s
  = do forking <- csmLift $ makeNonce "forking"
       tell ["{ csp::ScopedForking ",forking," ; "]
       call genStructured s (genPar' forking)
       tell [" }"]
       where
         genPar' :: String -> Meta -> A.Process -> CGen ()
         genPar' forking _ p
          = case p of 
             A.ProcCall _ n as -> 
               do tell [forking," .forkInThisThread(new proc_"]
                  genName n
                  tell ["("]
                  (A.Proc _ _ fs _) <- specTypeOfName n
                  call genActuals fs as
                  tell [" ) ); "] 
             _ -> error ("trying to run something other than a process in parallel")
      


-- | Changed to use C++CSP's Alternative class:
cppgenAlt :: Bool -> A.Structured A.Alternative -> CGen ()
cppgenAlt _ s 
  = do guards <- csmLift $ makeNonce "alt_guards"
       tell ["std::list< csp::Guard* > ", guards, " ; "]
       initAltGuards guards s
       alt <- csmLift $ makeNonce "alt"
       tell ["csp::Alternative ",alt, " ( ", guards, " ); "]

       id <- csmLift $ makeNonce "alt_id"
       tell ["int ", id, " = 0;\n"]
       fired <- csmLift $ makeNonce "alt_fired"
       tell ["int ", fired, " = ", alt, " .priSelect();"]
       label <- csmLift $ makeNonce "alt_end"
       tell ["{\n"]
       genAltProcesses id fired label s
       tell ["}\n"]
       tell [label, ":\n;\n"]
  where
    --This function is like the enable function in GenerateC, but this one merely builds a list of guards.  It does not do anything other than add to the guard list
    initAltGuards :: String -> A.Structured A.Alternative -> CGen ()
    initAltGuards guardList s = call genStructured s doA
      where
        doA  _ alt
            = case alt of
                A.Alternative _ e c im _ -> withIf e $ doIn c im
                A.AlternativeSkip _ e _ -> withIf e $ tell [guardList, " . push_back( new csp::SkipGuard() );\n"]

        doIn c im
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing "timer read in ALT"
                   A.InputTimerAfter _ time ->
                     do timeVal <- genCPPCSPTime time
                        tell [guardList, " . push_back( new csp::TimeoutGuard (",timeVal,"));\n"]
                   _ ->
                     do tell [guardList, " . push_back( "]
                        genCPPCSPChannelInput c
                        tell [" . inputGuard());\n"]

    -- This is the same as GenerateC for now -- but it's not really reusable
    -- because it's so closely tied to how ALT is implemented in the backend.
    genAltProcesses :: String -> String -> String -> A.Structured A.Alternative -> CGen ()
    genAltProcesses id fired label s = call genStructured s doA
      where
        doA _ alt
            = case alt of
                A.Alternative _ e c im p -> withIf e $ doIn c im p
                A.AlternativeSkip _ e p -> withIf e $ doCheck (call genProcess p)

        doIn c im p
            = do case im of
                   A.InputTimerRead _ _ -> call genMissing "timer read in ALT"
                   A.InputTimerAfter _ _ -> doCheck (call genProcess p)
                   _ -> doCheck (call genInput c im >> call genProcess p)

        doCheck body
            = do tell ["if (", id, "++ == ", fired, ") {\n"]
                 body
                 tell ["goto ", label, ";\n"]
                 tell ["}\n"]


-- | In GenerateC this uses prefixComma (because "Process * me" is always the first argument), but here we use infixComma.
cppgenActuals :: [A.Formal] -> [A.Actual] -> CGen ()
cppgenActuals fs as = infixComma [call genActual f a | (f, a) <- zip fs as]

-- | The only change from GenerateC is that passing "me" is not necessary in C++CSP
cppgenProcCall :: A.Name -> [A.Actual] -> CGen ()
cppgenProcCall n as 
    = do genName n
         tell ["("]
         (A.Proc _ _ fs _) <- specTypeOfName n
         call genActuals fs as
         tell [");"]

-- | Changed because we initialise channels and arrays differently in C++
cppdeclareInit :: Meta -> A.Type -> A.Variable -> Maybe (CGen ())
cppdeclareInit m t@(A.Array ds t') var
    = Just $ do case t' of
                  A.Chan A.DirUnknown _ _ ->
                    do tell ["tockInitChanArray("]
                       call genVariableUnchecked var
                       tell ["_storage,"]
                       call genVariableUnchecked var
                       tell [","]
                       sequence_ $ intersperse (tell ["*"])
                                               [call genExpression n
                                                | A.Dimension n <- ds]
                       tell [");"]
                  _ -> return ()
cppdeclareInit m rt@(A.Record _) var
    = Just $ do fs <- recordFields m rt
                sequence_ [initField t (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
  where
    initField :: A.Type -> A.Variable -> CGen ()
    initField t v = do fdeclareInit <- fget declareInit
                       doMaybe $ fdeclareInit m t v
cppdeclareInit _ _ _ = Nothing

-- | Changed because we don't need any de-initialisation in C++, regardless of whether C does.
cppdeclareFree :: Meta -> A.Type -> A.Variable -> Maybe (CGen ())
cppdeclareFree _ _ _ = Nothing

-- | Changed to work properly with declareFree to free channel arrays.
cppremoveSpec :: A.Specification -> CGen ()
cppremoveSpec (A.Specification m n (A.Declaration _ t))
    = do fdeclareFree <- fget declareFree
         case fdeclareFree m t var of
               Just p -> p
               Nothing -> return ()
  where
    var = A.Variable m n
-- Otherwise, defer to the C implementation:
cppremoveSpec sp = cremoveSpec sp

--Changed from GenerateC to add a name function (to allow us to use the same function for doing function parameters as constructor parameters)
--and also changed to use infixComma.
--Therefore these functions are not part of GenOps.  They are called directly by cppgenForwardDeclaration and cppintroduceSpec.
--To use for a constructor list, pass prefixUnderscore as the function, otherwise pass the identity function
cppgenFormals :: (A.Name -> A.Name) -> [A.Formal] -> CGen ()
cppgenFormals nameFunc list = infixComma (map (cppgenFormal nameFunc) list)

--Changed as genFormals
cppgenFormal :: (A.Name -> A.Name) -> A.Formal -> CGen ()
cppgenFormal nameFunc (A.Formal am t n) = call genDecl am t (nameFunc n)

cppgenForwardDeclaration :: A.Specification -> CGen()
cppgenForwardDeclaration (A.Specification _ n (A.Proc _ sm fs _))
    =  do --Generate the "process" as a C++ function:
          call genSpecMode sm
          tell ["void "]
          name 
          tell [" ("]
          cppgenFormals (\x -> x) fs
          tell [");"]

          --And generate its CSProcess wrapper:
          tell ["class proc_"]
          name
          tell [" : public csp::CSProcess {private:"]
          genClassVars fs
          tell ["public:inline proc_"]
          name
          tell ["("]
          cppgenFormals prefixUnderscore fs
          -- One of the cgtests declares an array of 200*100*sizeof(csp::Time).  
          -- Assuming csp::Time could be up to 16 bytes, we need half a meg stack: 
          tell [") : csp::CSProcess(524288)"]
          genConstructorList fs
          tell ["{} protected: virtual void run(); };"]
  where
    name = genName n

    --A simple function for generating declarations of class variables
    genClassVar :: A.Formal -> CGen()
    genClassVar (A.Formal am t n) 
        = do call genDecl am t n
             tell[";"]

    --Generates the given list of class variables
    genClassVars :: [A.Formal] -> CGen ()
    genClassVars fs = mapM_ genClassVar fs

    --A helper function for generating the initialiser list in a process wrapper constructor
    genConsItem :: A.Formal -> CGen()
    genConsItem (A.Formal am t n)
        = do tell[","]
             genName n
             tell["(_"]
             genName n
             tell[")"]

    --A function for generating the initialiser list in a process wrapper constructor
    genConstructorList :: [A.Formal] -> CGen ()
    genConstructorList fs = mapM_ genConsItem fs

cppgenForwardDeclaration (A.Specification _ n (A.RecordType _ b fs))
    = call genRecordTypeSpec n b fs
cppgenForwardDeclaration _ = return ()

cppintroduceSpec :: A.Specification -> CGen ()
--I generate process wrappers for all functions by default:
cppintroduceSpec (A.Specification _ n (A.Proc _ sm fs p))
    =  do --Generate the "process" as a C++ function:
          call genSpecMode sm
          tell ["void "]
          name 
          tell [" ("]
          cppgenFormals (\x -> x) fs
          tell [") {\n"]
          call genProcess p
          tell ["}\n"]                                                                          

          --And generate its CSProcess wrapper:
          tell ["void proc_"]
          name
          tell ["::run() { try {"]
          name
          tell [" ( "]
          genParamList fs
          tell [" ); } catch (StopException e) {std::cerr << \"Stopped because: \" << e.reason << std::endl; } }"]
  where
    name = genName n

    --A helper function for calling the wrapped functions:
    genParam :: A.Formal -> CGen()
    genParam (A.Formal _ _ n) = genName n

    --A helper function for calling the wrapped functions:
    genParamList :: [A.Formal] -> CGen()
    genParamList fs = infixComma $ map genParam fs

--For all other cases, use the C implementation:
cppintroduceSpec n = cintroduceSpec n

--}}}


--{{{  types
-- | If a type maps to a simple C type, return Just that; else return Nothing.
--Changed from GenerateC to change the A.Timer type to use C++CSP time.
--Also changed the bool type, because vector<bool> in C++ is odd, so we hide it from the compiler.
cppgetScalarType :: A.Type -> Maybe String
cppgetScalarType A.Bool = Just "bool"
cppgetScalarType A.Byte = Just "uint8_t"
cppgetScalarType A.UInt16 = Just "uint16_t"
cppgetScalarType A.UInt32 = Just "uint32_t"
cppgetScalarType A.UInt64 = Just "uint64_t"
cppgetScalarType A.Int8 = Just "int8_t"
cppgetScalarType A.Int | cxxIntSize == 2 = cppgetScalarType A.Int16
                       | cxxIntSize == 4 = cppgetScalarType A.Int32
                       | cxxIntSize == 8 = cppgetScalarType A.Int64
cppgetScalarType A.Int16 = Just "int16_t"
cppgetScalarType A.Int32 = Just "int32_t"
cppgetScalarType A.Int64 = Just "int64_t"
cppgetScalarType A.Real32 = Just "float"
cppgetScalarType A.Real64 = Just "double"
cppgetScalarType (A.Timer A.OccamTimer) = Just "csp::Time"
cppgetScalarType A.Time = Just "csp::Time"
cppgetScalarType _ = Nothing

-- | Changed from GenerateC to change the arrays and the channels
--Also changed to add counted arrays and user protocols
cppgenType :: A.Type -> CGen ()
cppgenType arr@(A.Array _ _)
    =  cgenType arr
cppgenType (A.Record n) = genName n
cppgenType (A.Chan dir attr t)
    = do let chanType = case dir of
                          A.DirInput -> "csp::Chanin"
                          A.DirOutput -> "csp::Chanout"
                          A.DirUnknown ->
                            case (A.caWritingShared attr,A.caReadingShared attr) of
                              (False,False) -> "csp::One2OneChannel"
                              (False,True)  -> "csp::One2AnyChannel"
                              (True,False)  -> "csp::Any2OneChannel"
                              (True,True)   -> "csp::Any2AnyChannel"
         tell [chanType,"<"]
         cppTypeInsideChannel t
         tell [">/**/"]
  where
    cppTypeInsideChannel :: A.Type -> CGen ()
    cppTypeInsideChannel A.Any = tell ["tockSendableArrayOfBytes"]
    cppTypeInsideChannel (A.Counted _ _) = tell ["tockSendableArrayOfBytes"]
    cppTypeInsideChannel (A.UserProtocol _) = tell ["tockSendableArrayOfBytes"]
    cppTypeInsideChannel (A.Array ds t)
      = do tell ["tockSendableArray<"]
           call genType t
           tell [","]
           sequence_ $ intersperse (tell ["*"]) [call genExpression n | A.Dimension n <- ds]
           tell [">/**/"]
    cppTypeInsideChannel t = call genType t
cppgenType (A.Mobile t@(A.Array {})) = call genType t
cppgenType (A.Mobile t@(A.List {})) = call genType t
cppgenType (A.Mobile t) = call genType t >> tell ["*"]
cppgenType (A.List t) = tell ["tockList<"] >> call genType t >> tell [">/**/"]
cppgenType t
 = do fgetScalarType <- fget getScalarType
      case fgetScalarType t of
        Just s -> tell [s]
        Nothing -> call genMissingC $ formatCode "genType %" t

cppgenListAssign :: A.Variable -> A.Expression -> CGen ()
cppgenListAssign v e
  = do call genVariable v
       tell ["="]
       call genExpression e
       tell [";"]

cppgenListSize :: A.Variable -> CGen ()
cppgenListSize v
 = do call genVariable v
      tell [".size()"]

cppgenListLiteral :: [A.Expression] -> A.Type -> CGen ()
cppgenListLiteral es t
 = do call genType t
      tell ["()"]
      mapM_ (\e -> tell ["("] >> call genExpression e >> tell [")"]) es

cppgenListConcat :: A.Expression -> A.Expression -> CGen ()
cppgenListConcat a b
  = do tell ["("]
       call genExpression a
       tell ["+"]
       call genExpression b
       tell [")"]

cppgenReplicatorLoop :: A.Name -> A.Replicator -> CGen ()
cppgenReplicatorLoop n rep@(A.For {}) = cgenReplicatorLoop n rep
cppgenReplicatorLoop n (A.ForEach m (A.ExprVariable _ v))
  = do t <- astTypeOf v
       call genType t
       tell ["::iterator "]
       genName n
       tell ["="]
       call genVariable v
       tell [".beginSeqEach();"] --TODO what if this is a pareach?
       genName n
       tell ["!="]
       call genVariable v
       tell [".limitIterator();"]
       genName n
       tell ["++"]
       -- TODO call endSeqEach

-- | Helper function for prefixing an underscore to a name.
prefixUnderscore :: A.Name -> A.Name
prefixUnderscore n = n { A.nameName = "_" ++ A.nameName n }


-- TODO I think I can remove both these unfolded expression things now that
-- I've changed the arrays

-- | Changed to remove array size:
cppgenUnfoldedExpression :: A.Expression -> CGen ()
cppgenUnfoldedExpression (A.Literal _ t lr)
    =  call genLiteralRepr lr t
cppgenUnfoldedExpression (A.ExprVariable m var) = call genUnfoldedVariable m var
cppgenUnfoldedExpression e = call genExpression e

-- | Changed to remove array size:
cppgenUnfoldedVariable :: Meta -> A.Variable -> CGen ()
cppgenUnfoldedVariable m var
    =  do t <- astTypeOf var
          case t of
            A.Record _ ->
              do genLeftB
                 fs <- recordFields m t
                 seqComma [call genUnfoldedVariable m (A.SubscriptedVariable m (A.SubscriptField m n) var)
                           | (n, t) <- fs]
                 genRightB
            -- We can defeat the usage check here because we know it's safe; *we're*
            -- generating the subscripts.
            -- FIXME Is that actually true for something like [a[x]]?
            _ -> call genVariableUnchecked var

--{{{  if
-- | Changed to throw a nonce-exception class instead of the goto, because C++ doesn't allow gotos to cross class initialisations (such as arrays)

cppgenIf :: Meta -> A.Structured A.Choice -> CGen ()
cppgenIf m s | justOnly s = do call genStructured s doCplain
                               tell ["{"]
                               call genStop m "no choice matched in IF process"
                               tell ["}"]
             | otherwise
    =  do ifExc <- csmLift $ makeNonce "if_exc"
          tell ["class ",ifExc, "{};try{"]
          genIfBody ifExc s
          call genStop m "no choice matched in IF process"
          tell ["}catch(",ifExc,"){}"]
  where
    genIfBody :: String -> A.Structured A.Choice -> CGen ()
    genIfBody ifExc s = call genStructured s doC
      where
        doC m (A.Choice m' e p)
            = do tell ["if("]
                 call genExpression e
                 tell ["){"]
                 call genProcess p
                 tell ["throw ",ifExc, "();}"]
    doCplain _ (A.Choice _ e p)
      = do tell ["if("]
           call genExpression e
           tell ["){"]
           call genProcess p
           tell ["}else "]

--}}}

-- | Changed because C++CSP has channel-ends as concepts (whereas CCSP does not)
cppgenDirectedVariable :: CGen () -> A.Direction -> CGen ()
cppgenDirectedVariable v A.DirInput = tell ["(("] >> v >> tell [")->reader())"]
cppgenDirectedVariable v A.DirOutput = tell ["(("] >> v >> tell [")->writer())"]
cppgenDirectedVariable v dir = call genMissing $ "Cannot direct variable to direction: " ++ show dir

cppgenAllocMobile :: Meta -> A.Type -> Maybe A.Expression -> CGen ()
cppgenAllocMobile m (A.Mobile t) me
  = do tell ["new "]
       call genType t 
       case me of
         Just e -> tell ["("] >> call genExpression e >> tell [")"]
         Nothing -> return ()

cppgenClearMobile :: Meta -> A.Variable -> CGen ()
cppgenClearMobile _ v
  = do tell ["if("]
       genVar
       tell ["!=NULL){delete "]
       genVar
       tell [";"]
       genVar
       tell ["=NULL;}"]
  where
    genVar = call genVariable v
