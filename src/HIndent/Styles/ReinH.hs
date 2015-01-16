{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}

module HIndent.Styles.ReinH where

import           Control.Applicative                    ((<$>))
import           Control.Monad                          (replicateM_, unless,
                                                         when)
import           Control.Monad.State                    (get, gets, put)
import           Data.Foldable
import           Data.Maybe

import           HIndent.Pretty
import           HIndent.Types

import           Language.Haskell.Exts.Annotated.Syntax
import           Language.Haskell.Exts.Comments
import           Language.Haskell.Exts.SrcLoc
import           Prelude                                hiding (all, and, any,
                                                         exp, mapM_, maximum,
                                                         minimum)

-- | Empty state.
data State = State

-- | The printer style.
reinh :: Style
reinh =
  Style { styleName = "reinh"
        , styleAuthor = "Rein Henrichs"
        , styleDescription = "Andrew Gibiansky's style"
        , styleInitialState = State
        , styleExtenders = [ Extender imp
                           , Extender context
                           , Extender derivings
                           , Extender typ
                           , Extender exprs
                           , Extender rhss
                           , Extender guardedRhs
                           , Extender decls
                           , Extender condecls
                           , Extender alt
                           , Extender moduleHead
                           , Extender exportList
                           , Extender fieldUpdate
                           ]
        , styleDefConfig =
           defaultConfig { configMaxColumns = 100
                         , configIndentSpaces = indentSpaces
                         , configClearEmptyLines =  True
                         }
        }

-- | Number of spaces to indent by.
indentSpaces :: Integral a => a
indentSpaces = 2

-- | Printer to indent one level.
indentOnce :: Printer ()
indentOnce = replicateM_ indentSpaces $ write " "

-- | How many exports to format in a single line.
-- If an export list has more than this, it will be formatted as multiple lines.
maxSingleLineExports :: Integral a => a
maxSingleLineExports = 4

attemptSingleLine :: Printer a -> Printer a -> Printer a
attemptSingleLine single multiple = do
  -- Try printing on one line.
  prevState <- get
  result <- single

  --  If it doesn't fit, reprint on multiple lines.
  col <- getColumn
  maxColumns <- configMaxColumns <$> gets psConfig
  if col > maxColumns
    then do
      put prevState
      multiple
    else
      return result

--------------------------------------------------------------------------------
-- Extenders

type Extend f = forall t. t -> f NodeInfo -> Printer ()


-- | Format import statements.
imp :: Extend ImportDecl
imp _ ImportDecl{..} = do
  write "import "
  write $ if importQualified
          then "qualified "
          else "          "
  pretty importModule

  forM_ importAs $ \name -> do
    write " as "
    pretty name

  forM_ importSpecs $ \speclist -> do
    write " "
    pretty speclist

-- | Format contexts with spaces and commas between class constraints.
context :: Extend Context
context _ (CxTuple _ asserts) =
  parens $ inter (comma >> space) $ map pretty asserts
context _ ctx = prettyNoExt ctx

-- | Format deriving clauses with spaces and commas between class constraints.
derivings :: Extend Deriving
derivings _ (Deriving _ instHeads) = do
  write "deriving "
  go instHeads

  where
    go insts | length insts == 1
             = pretty $ head insts
             | otherwise
             = parens $ inter (comma >> space) $ map pretty insts

-- | Format function type declarations.
typ :: Extend Type

-- For contexts, check whether the context and all following function types
-- are on the same line. If they are, print them on the same line; otherwise
-- print the context and each argument to the function on separate lines.
typ _ (TyForall _ _ (Just ctx) rest) =
  if all (sameLine ctx) $ collectTypes rest
  then do
    pretty ctx
    write " => "
    pretty rest
  else do
    col <- getColumn
    pretty ctx
    column (col - 3) $ do
      newline
      write  "=> "
      indented 3 $ pretty rest

typ _ (TyTuple _ boxed types) = parens $ do
  boxed'
  inter (write ", ") $ map pretty types
  boxed'

  where
    boxed' = case boxed of
      Boxed   -> return ()
      Unboxed -> write "#"

typ _ ty@(TyFun _ from to) =
  -- If the function argument types are on the same line,
  -- put the entire function type on the same line.
  if all (sameLine from) $ collectTypes ty
  then do
    pretty from
    write " -> "
    pretty to
  -- If the function argument types are on different lines,
  -- write one argument type per line.
  else do
    col <- getColumn
    pretty from
    column (col - 3) $ do
      newline
      write "-> "
      indented 3 $ pretty to
typ _ t = prettyNoExt t

sameLine :: (Annotated ast, Annotated ast') => ast NodeInfo -> ast' NodeInfo -> Bool
sameLine x y = line x == line y
  where
    line :: Annotated ast => ast NodeInfo -> Int
    line = startLine . nodeInfoSpan . ann

collectTypes :: Type l -> [Type l]
collectTypes (TyFun _ from to) = from : collectTypes to
collectTypes ty = [ty]

exprs :: Extend Exp
exprs _ exp@Let{} = letExpr exp
exprs _ exp@App{} = appExpr exp
exprs _ exp@Do{} = doExpr exp
exprs _ exp@List{} = listExpr exp
exprs _ exp@(InfixApp _ _ (QVarOp _ (UnQual _ (Symbol _ "$"))) _) = dollarExpr exp
exprs _ exp@(InfixApp _ _ (QVarOp _ (UnQual _ (Symbol _ "<*>"))) _) = applicativeExpr exp
exprs _ exp@Lambda{} = lambdaExpr exp
exprs _ exp@Case{} = caseExpr exp
exprs _ exp@LCase{} = lambdaCaseExpr exp
exprs _ (RecUpdate _ exp updates) = recUpdateExpr (pretty exp) updates
exprs _ (RecConstr _ qname updates) = recUpdateExpr (pretty qname) updates
exprs _ (Tuple _ _ exps) = parens $ inter (write ", ") $ map pretty exps
exprs _ exp = prettyNoExt exp

letExpr :: Exp NodeInfo -> Printer ()
letExpr (Let _ binds result) = do
  cols <- depend (write "let ") $ do
    col <- getColumn
    pretty binds
    return $ col - 4
  column cols $ do
    newline
    write "in "
    pretty result
letExpr _ = error "Not a let"

appExpr :: Exp NodeInfo -> Printer ()
appExpr app@(App _ f x) = do
  prevState <- get
  prevLine <- getLineNum
  attemptSingleLine singleLine multiLine
  curLine <- getLineNum

  -- If the multiline version takes more than two lines,
  -- print everything with one argument per line.
  when (curLine - prevLine > 1) $ do
    -- Restore to before printing.
    put prevState

    allArgsSeparate <- not <$> canSingleLine (pretty f)
    if allArgsSeparate
      then separateArgs app
      else do
        col <- getColumn
        column col $ do
          pretty f
          newline
          indented indentSpaces $ pretty x

  where
    singleLine = spaced [pretty f, pretty x]
    multiLine = do
      col <- getColumn
      column col $ do
        pretty f
        newline
        indentOnce
        pretty x

    canSingleLine :: Printer a -> Printer Bool
    canSingleLine printer = do
      st <- get
      prevLine <- getLineNum
      _ <- printer
      curLine <- getLineNum
      put st
      return $ prevLine == curLine

    -- Separate a function application into the function
    -- and all of its arguments. Arguments are returned in reverse order.
    collectArgs :: Exp NodeInfo -> (Exp NodeInfo, [Exp NodeInfo])
    collectArgs (App _ g y) =
      let (fun, args) = collectArgs g in
        (fun, y : args)
    collectArgs nonApp = (nonApp, [])

    separateArgs :: Exp NodeInfo -> Printer ()
    separateArgs expr =
      let (fun, args) = collectArgs expr
      in do
        col <- getColumn
        column col $ do
          pretty fun
          newline
          indented indentSpaces $ lined $ map pretty $ reverse args

appExpr _ = error "Not an app"

doExpr :: Exp NodeInfo -> Printer ()
doExpr (Do _ stmts) = do
  write "do"
  newline
  indented 2 $ lined (map pretty stmts)
doExpr _ = error "Not a do"

listExpr :: Exp NodeInfo -> Printer ()
listExpr (List _ els) = attemptSingleLine (singleLineList els) (multiLineList els)
listExpr _ = error "Not a list"

singleLineList :: [Exp NodeInfo] -> Printer ()
singleLineList exps = do
  write "["
  inter (write ", ") $ map pretty exps
  write "]"

multiLineList :: [Exp NodeInfo] -> Printer ()
multiLineList [] = write "[]"
multiLineList (first:exps) = do
  col <- getColumn
  ind <- gets psIndentLevel
  column (max col ind) $ do
    write "[ "
    pretty first
    forM_ exps $ \el -> do
      newline
      write ", "
      pretty el
    newline
    write "]"

dollarExpr :: Exp NodeInfo -> Printer ()
dollarExpr (InfixApp _ left op right) = do
  pretty left
  write " "
  pretty op
  if needsNewline right
    then do
      newline
      depend indentOnce $ pretty right
    else do
      write " "
      pretty right
  where
    needsNewline Case{} = True
    needsNewline _ = False
dollarExpr _ = error "Not an application"

applicativeExpr :: Exp NodeInfo -> Printer ()
applicativeExpr exp@InfixApp{} =
  case applicativeArgs of
    Just (first:second:rest) ->
      attemptSingleLine (singleLine first second rest) (multiLine first second rest)
    _ -> prettyNoExt exp
  where
    singleLine :: Exp NodeInfo -> Exp NodeInfo -> [Exp NodeInfo] -> Printer ()
    singleLine first second rest = spaced
      [ pretty first
      , write "<$>"
      , pretty second
      , write "<*>"
      , inter (write " <*> ") $ map pretty rest
      ]

    multiLine :: Exp NodeInfo -> Exp NodeInfo -> [Exp NodeInfo] -> Printer ()
    multiLine first second rest = do
      pretty first
      depend (write " ") $ do
        write "<$> "
        pretty second
        forM_ rest $ \val -> do
          newline
          write "<*> "
          pretty val

    applicativeArgs :: Maybe [Exp NodeInfo]
    applicativeArgs = collectApplicativeExps exp

    collectApplicativeExps :: Exp NodeInfo -> Maybe [Exp NodeInfo]
    collectApplicativeExps (InfixApp _ left op right)
      | isFmap op = return [left, right]
      | isAp op = do
          start <- collectApplicativeExps left
          return $ start ++ [right]
      | otherwise = Nothing
    collectApplicativeExps x = return [x]

    isFmap :: QOp NodeInfo -> Bool
    isFmap (QVarOp _ (UnQual _ (Symbol _ "<$>"))) = True
    isFmap _ = False

    isAp :: QOp NodeInfo -> Bool
    isAp (QVarOp _ (UnQual _ (Symbol _ "<*>"))) = True
    isAp _ = False
applicativeExpr _ = error "Not an application"

lambdaExpr :: Exp NodeInfo -> Printer ()
lambdaExpr (Lambda _ pats exp) = do
  write "\\"
  spaced $ map pretty pats
  write " ->"
  attemptSingleLine (write " " >> pretty exp) $ do
    newline
    indentOnce
    pretty exp
lambdaExpr _ = error "Not a lambda"

caseExpr :: Exp NodeInfo -> Printer ()
caseExpr (Case _ exp alts) = do

  depend (write "case ") $ do
    pretty exp
    write " of"
  newline

  writeCaseAlts alts
caseExpr _ = error "Not a case"

lambdaCaseExpr :: Exp NodeInfo -> Printer ()
lambdaCaseExpr (LCase _ alts) = do
  write "\\case"
  newline
  writeCaseAlts alts
lambdaCaseExpr _ = error "Not a lambda case"


writeCaseAlts :: [Alt NodeInfo] -> Printer ()
writeCaseAlts alts = do
  allSingle <- and <$> mapM isSingle alts
  withCaseContext True $ indented indentSpaces $
    if allSingle
    then do
      maxPatLen <- maximum <$> mapM (patternLen . altPattern) alts
      lined $ map (prettyCase $ Just maxPatLen) alts
    else lined $ map (prettyCase Nothing) alts
  where
    isSingle :: Alt NodeInfo -> Printer Bool
    isSingle alt' = fst <$> sandbox (do
      line <- gets psLine
      pretty alt'
      line' <- gets psLine
      return $ line == line')

    altPattern :: Alt l -> Pat l
    altPattern (Alt _ p _ _) = p

    patternLen :: Pat NodeInfo -> Printer Int
    patternLen pat = fromIntegral <$> fst <$> sandbox (do
      col <- getColumn
      pretty pat
      col' <- getColumn
      return $ col' - col)

    prettyCase :: Maybe Int -> Alt NodeInfo -> Printer ()
    prettyCase mpatlen (Alt _ p galts mbinds) = do
      -- Padded pattern
      case mpatlen of
        Just patlen -> do
          col <- getColumn
          pretty p
          col' <- getColumn
          replicateM_ (patlen - fromIntegral (col' - col)) space
        Nothing -> pretty p

      case galts of
        UnGuardedRhs{} -> pretty galts
        GuardedRhss{} -> indented indentSpaces $ pretty galts

      --  Optional where clause!
      forM_ mbinds $ \binds -> do
        newline
        indented indentSpaces $ depend (write "where ") (pretty binds)



recUpdateExpr :: Printer () -> [FieldUpdate NodeInfo] -> Printer ()
recUpdateExpr expWriter updates = do
  expWriter
  write " "
  if null updates
    then write "{}"
    else attemptSingleLine single mult

  where
    single = do
      write "{ "
      inter (write ", ") $ map pretty updates
      write " }"
    mult = do
      col <- getColumn
      column col $ do
        write "{ "
        pretty (head updates)
        forM_ (tail updates) $ \update -> do
          newline
          write ", "
          pretty update
        newline
        write "}"

rhss :: Extend Rhs
rhss _ (UnGuardedRhs _ exp) = do
  write " "
  rhsSeparator
  if onNextLine exp
    then indented indentSpaces $ do
      newline
      pretty exp
    else do
      space
      pretty exp

  where
    onNextLine Let{} = True
    onNextLine _ = False
rhss _ (GuardedRhss _ rs) =
  lined $ flip map rs $ \a@(GuardedRhs _ stmts exp) -> do
    printComments Before a
    write "| "
    inter (write ", ") $ map pretty stmts
    write " "
    rhsSeparator
    write " "
    pretty exp

guardedRhs :: Extend GuardedRhs
guardedRhs _ (GuardedRhs _ stmts exp) = do
  indented 1 $ prefixedLined "," (map (\p -> space >> pretty p) stmts)
  write " "
  rhsSeparator
  write " "
  pretty exp

-- | Is the decl a record?
isRecord :: QualConDecl t -> Bool
isRecord (QualConDecl _ _ _ RecDecl{}) = True
isRecord _ = False

-- | Use special record display, used by 'dataDecl' in a record scenario.
qualConDecl :: QualConDecl NodeInfo -> Printer ()
qualConDecl x =
    case x of
        QualConDecl _ tyvars ctx d ->
            depend
                (unless
                     (null (fromMaybe [] tyvars))
                     (do write "forall "
                         spaced (map pretty (fromMaybe [] tyvars))
                         write ". "))
                (depend
                     (maybeCtx ctx)
                     (recDecl d))

-- | Record decls are formatted like: Foo
-- { bar :: X
-- }
recDecl :: ConDecl NodeInfo -> Printer ()
recDecl (RecDecl _ name fields) =
  do pretty name
     indentSpaces <- getIndentSpaces
     newline
     column indentSpaces
            (do depend (write "{")
                       (prefixedLined ","
                                      (map (depend space . pretty) fields))
                newline
                write "} ")
recDecl r = prettyNoExt r


decls :: Extend Decl

decls _ (DataDecl _ dataornew ctx dhead condecls@[_] mderivs)
  | any isRecord condecls =
    do depend (do pretty dataornew
                  unless (null condecls) space)
              (depend (maybeCtx ctx)
                      (do pretty dhead
                          multiCons condecls))
       case mderivs of
         Nothing -> return ()
         Just derivs -> pretty derivs
  where multiCons xs =
          depend (write " =")
                 (inter (write "|")
                        (map (depend space . qualConDecl) xs))

-- decls _ (DataDecl _ dataOrNew Nothing declHead constructors mayDeriving) = do
--   pretty dataOrNew
--   write " "
--   pretty declHead
--   case constructors of
--     []  -> return ()
--     [x] -> do
--       write " = "
--       pretty x
--     (x:xs) ->
--       depend (write " ") $ do
--         write "= "
--         pretty x
--         forM_ xs $ \constructor -> do
--           newline
--           write "| "
--           pretty constructor

--   forM_ mayDeriving $ \deriv -> do
--     newline
--     indented indentSpaces $ pretty deriv

decls _ (PatBind _ pat rhs mbinds) = funBody [pat] rhs mbinds
decls _ (FunBind _ matches) =
  lined $  flip map matches $ \match -> do
    (name, pat, rhs, mbinds) <-
      case match of
        Match _ name pat rhs mbinds -> return (name, pat, rhs, mbinds)
        InfixMatch _ left name pat rhs mbinds -> do
          pretty left
          write " "
          return (name, pat, rhs, mbinds)

    pretty name
    write " "
    funBody pat rhs mbinds
decls _ decl = prettyNoExt decl

funBody :: [Pat NodeInfo] -> Rhs NodeInfo -> Maybe (Binds NodeInfo) -> Printer ()
funBody pat rhs mbinds = do
  spaced $ map pretty pat

  withCaseContext False $ case rhs of
    UnGuardedRhs{} -> pretty rhs
    GuardedRhss{}  -> do
      newline
      indented indentSpaces $ pretty rhs

  -- Process the binding group, if it exists.
  forM_ mbinds $ \binds -> do
    newline
    -- Add an extra newline after do blocks.
    when (isDoBlock rhs) newline
    indented indentSpaces $ do
      write "where"
      newline
      indented indentSpaces $ writeWhereBinds binds

writeWhereBinds :: Binds NodeInfo -> Printer ()
writeWhereBinds ds@(BDecls _ binds@(first:rest)) = do
  printComments Before ds
  pretty first
  forM_ (zip binds rest) $ \(prev, cur) -> do
    replicateM_ (max 1 $ lineDelta cur prev) newline
    pretty cur
writeWhereBinds binds = prettyNoExt binds

astStartLine :: Annotated ast => ast NodeInfo -> Int
astStartLine decl =
  let info = ann decl
      comments = nodeInfoComments info
      befores = filter ((== Just Before) . comInfoLocation) comments
      commentStartLine (Comment _ sp _) = srcSpanStartLine sp
  in if null befores
     then startLine $ nodeInfoSpan info
     else minimum $ map (commentStartLine . comInfoComment) befores

isDoBlock :: Rhs l -> Bool
isDoBlock (UnGuardedRhs _ Do{}) = True
isDoBlock _ = False

condecls :: Extend ConDecl
condecls _ (ConDecl _ name bangty) =
  depend (pretty name) $
    forM_ bangty $ \ty -> space >> pretty ty
condecls _ (RecDecl _ name fields) =
  depend (pretty name >> space) $ do
    write "{ "
    case fields of
      []         -> return ()
      [x]        -> do
        pretty x
        eol <- gets psEolComment
        unless eol space

      first:rest -> do
        pretty first
        newline
        forM_ rest $ \field -> do
          comma
          space
          pretty field
          newline
    write "}"
condecls _ other = prettyNoExt other

alt :: Extend Alt
alt _ (Alt _ p rhs mbinds) = do
  pretty p
  case rhs of
    UnGuardedRhs{} -> pretty rhs
    GuardedRhss{}  -> indented indentSpaces $ pretty rhs
  forM_ mbinds $ \binds -> do
    newline
    indented indentSpaces $
      depend (write "where ") (pretty binds)

moduleHead :: Extend ModuleHead
moduleHead _ (ModuleHead _ name mwarn mexports) = do
  forM_ mwarn pretty
  write "module "
  pretty name
  forM_ mexports $ \exports -> do
    space
    pretty exports
  write " where"

exportList :: Extend ExportSpecList
exportList _ (ExportSpecList _ exports) = do
  write "("
  if length exports <= maxSingleLineExports
    then do
      inter (write ", ") $ map pretty exports
      write ")"
    else indented indentSpaces' $ do
      -- First export
      let first:rest = exports
      newline
      pretty first
      write ","

      forM_ (zip rest exports) $ \(cur, prev) -> do
        replicateM_ (max 1 $ lineDelta cur prev) newline
        pretty cur
        write ","
      newline
      write ")"
  where
    indentSpaces' = 2 * indentSpaces

lineDelta :: (Annotated ast1, Annotated ast2) => ast1 NodeInfo -> ast2 NodeInfo -> Int
lineDelta cur prev = emptyLines
  where
    prevLine = srcSpanEndLine . srcInfoSpan . nodeInfoSpan . ann $ prev
    curLine = astStartLine cur
    emptyLines = curLine - prevLine

fieldUpdate :: Extend FieldUpdate
fieldUpdate _ (FieldUpdate _ name val) = do
  pretty name
  write " = "
  pretty val
fieldUpdate _ upd = prettyNoExt upd
