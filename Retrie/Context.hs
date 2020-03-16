-- Copyright (c) Facebook, Inc. and its affiliates.
--
-- This source code is licensed under the MIT license found in the
-- LICENSE file in the root directory of this source tree.
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Retrie.Context
  ( ContextUpdater
  , updateContext
  , emptyContext
  ) where

import Control.Monad.IO.Class
import Data.Char (isDigit)
import Data.Either (partitionEithers)
import Data.Generics hiding (Fixity)
import Data.List
import Data.Maybe

import Retrie.AlphaEnv
import Retrie.ExactPrint
import Retrie.Fixity
import Retrie.FreeVars
import Retrie.GHC
import Retrie.Substitution
import Retrie.SYB
import Retrie.Types
import Retrie.Universe

-------------------------------------------------------------------------------

-- | Type of context update functions for 'apply'.
-- When defining your own 'ContextUpdater', you probably want to extend
-- 'updateContext' using SYB combinators such as 'mkQ' and 'extQ'.
type ContextUpdater = forall m. MonadIO m => GenericCU (TransformT m) Context

-- | Default context update function.
updateContext :: forall m. MonadIO m => GenericCU (TransformT m) Context
updateContext c i =
  const (return c)
    `extQ` (return . updExp)
    `extQ` (return . updType)
#if __GLASGOW_HASKELL__ < 806
    `extQ` (return . updTypeList)
#endif
    `extQ` (return . updMatch)
    `extQ` (return . updGRHSs)
    `extQ` (return . updGRHS)
    `extQ` (return . updStmt)
    `extQ` updStmtList
    `extQ` (return . updHsBind)
    `extQ` (return . updTyClDecl)
  where
    neverParen = c { ctxtParentPrec = NeverParen }

    updExp :: HsExpr GhcPs -> Context
    updExp HsApp{} =
      c { ctxtParentPrec = HasPrec $ Fixity (SourceText "HsApp") (10 + i - firstChild) InfixL }
    -- Reason for 10 + i: (i is index of child, 0 = left, 1 = right)
    -- In left child, prec is 10, so HsApp child will NOT get paren'd
    -- In right child, prec is 11, so every child gets paren'd (unless atomic)
#if __GLASGOW_HASKELL__ < 806
    updExp (OpApp _ op _ _) = c { ctxtParentPrec = HasPrec $ lookupOp op (ctxtFixityEnv c) }
    updExp (HsLet lbs _) = addInScope neverParen $ collectLocalBinders $ unLoc lbs
#else
    updExp (OpApp _ _ op _) = c { ctxtParentPrec = HasPrec $ lookupOp op (ctxtFixityEnv c) }
    updExp (HsLet _ lbs _) = addInScope neverParen $ collectLocalBinders $ unLoc lbs
#endif
    updExp _ = neverParen

    updType :: HsType GhcPs -> Context
#if __GLASGOW_HASKELL__ < 806
    updType (HsAppsTy _) = c { ctxtParentPrec = IsHsAppsTy }
#else
    updType HsAppTy{}
      | i > firstChild = c { ctxtParentPrec = IsHsAppsTy }
#endif
    updType _ = neverParen

#if __GLASGOW_HASKELL__ < 806
    updTypeList :: [LHsAppType GhcPs] -> Context
    updTypeList _ =
      case ctxtParentPrec c of
        IsHsAppsTy
          | i > 0 -> c { ctxtParentPrec = HasPrec $ Fixity (SourceText "HsAppsTy") 11 InfixL }
          | otherwise -> neverParen
        _ -> c -- leave prec as is
#endif

    updMatch :: Match GhcPs (LHsExpr GhcPs) -> Context
    updMatch = addInScope neverParen . collectPatsBinders . m_pats

    updGRHSs :: GRHSs GhcPs (LHsExpr GhcPs) -> Context
    updGRHSs = addInScope neverParen . collectLocalBinders . unLoc . grhssLocalBinds

    updGRHS :: GRHS GhcPs (LHsExpr GhcPs) -> Context
#if __GLASGOW_HASKELL__ < 806
    updGRHS (GRHS gs _)
#else
    updGRHS XGRHS{} = neverParen
    updGRHS (GRHS _ gs _)
#endif
        -- binders are in scope over the body (right child) only
      | i > firstChild = addInScope neverParen bs
      | otherwise = fst $ updateSubstitution neverParen bs
      where
        bs = collectLStmtsBinders gs

    updStmt :: Stmt GhcPs (LHsExpr GhcPs) -> Context
#if __GLASGOW_HASKELL__ < 806
    updStmt (BindStmt p _body _ _ _)
#else
    updStmt (BindStmt _ p _body _ _)
#endif
      -- i > firstChild == 'for the body'
      | i > firstChild = addBinders neverParen (collectPatBinders p)
    updStmt _ = neverParen

    updStmtList :: [LStmt GhcPs (LHsExpr GhcPs)] -> TransformT m Context
    updStmtList [] = return neverParen
    updStmtList (ls:_)
        -- binders are in scope over tail of list (right child)
      | i > 0 = insertDependentRewrites neverParen bs ls
        -- lets are recursive in do-blocks
#if __GLASGOW_HASKELL__ < 806
      | L _ (LetStmt (L _ bnds)) <- ls =
#else
      | L _ (LetStmt _ (L _ bnds)) <- ls =
#endif
          return $ addInScope neverParen $ collectLocalBinders bnds
      | otherwise = return $ fst $ updateSubstitution neverParen bs
      where
        bs = collectLStmtBinders ls

    updHsBind :: HsBind GhcPs -> Context
    updHsBind FunBind{..} =
      let rdr = unLoc fun_id
      in addBinders (addInScope neverParen [rdr]) [rdr]
    updHsBind _ = neverParen

    updTyClDecl :: TyClDecl GhcPs -> Context
    updTyClDecl SynDecl{..} = addInScope neverParen [unLoc tcdLName]
    updTyClDecl DataDecl{..} = addInScope neverParen [unLoc tcdLName]
    updTyClDecl ClassDecl{..} = addInScope neverParen [unLoc tcdLName]
    updTyClDecl _ = neverParen

-- | Create an empty 'Context' with given 'FixityEnv', rewriter, and dependent
-- rewrite generator.
emptyContext :: FixityEnv -> Rewriter -> Rewriter -> Context
emptyContext ctxtFixityEnv ctxtRewriter ctxtDependents = Context{..}
  where
    ctxtBinders = []
    ctxtInScope = emptyAlphaEnv
    ctxtParentPrec = NeverParen
    ctxtSubst = Nothing

-- Deal with Trees-That-Grow adding extension points
-- as the first child everywhere.
firstChild :: Int
#if __GLASGOW_HASKELL__ < 806
firstChild = 0
#else
firstChild = 1
#endif

-- | Add dependent rewrites to 'ctxtRewriter' if necessary.
insertDependentRewrites
  :: (Matchable k, MonadIO m) => Context -> [RdrName] -> k -> TransformT m Context
insertDependentRewrites c bs x = do
  r <- runRewriter id c (ctxtDependents c) x
  let
    c' = addInScope c bs
  case r of
    NoMatch -> return c'
    MatchResult _ Template{..} -> do
      let
        rrs = fromMaybe [] tDependents
        ds = rewritesWithDependents rrs
        f = foldMap (mkLocalRewriter $ ctxtInScope c')
      return c'
        { ctxtRewriter = f rrs <> ctxtRewriter c'
        , ctxtDependents = f ds <> ctxtDependents c'
        }

-- | Add set of binders to 'ctxtInScope'.
addInScope :: Context -> [RdrName] -> Context
addInScope c bs =
  c' { ctxtInScope = foldr extendAlphaEnv (ctxtInScope c') bs' }
  where
    (c', bs') = updateSubstitution c bs

-- | Add set of binders to 'ctxtBinders'.
addBinders :: Context -> [RdrName] -> Context
addBinders c bs = c { ctxtBinders = bs ++ ctxtBinders c }

-- Capture-avoiding substitution
--------------------------------------------------------------------------------

-- | Update the Context's substitution appropriately for a set of binders.
-- Returns a new Context and a potentially alpha-renamed set of binders.
updateSubstitution :: Context -> [RdrName] -> (Context, [RdrName])
updateSubstitution c rdrs =
  case ctxtSubst c of
    Nothing -> (c, rdrs)
    Just sub ->
      let
        -- This prevents substituting for 'x' under a binding for 'x'.
        sub' = deleteSubst sub $ map rdrFS rdrs
        -- Compute free vars of substitution that could possibly be captured.
        fvs = substFVs sub'
        -- Partition binders into noncapturing and capturing.
        (noncapturing, capturing) =
          partitionEithers $ map (updateBinder fvs) rdrs
        -- Extend substitution with alpha-renamings.
        alphaSub = foldl' (uncurry . extendSubst) sub'
          [ (rdrFS rdr, HoleRdr rdr') | (rdr, rdr') <- capturing ]
        -- There are no telescopes in source Haskell, so order doesn't matter.
        -- Capturing should be rare, so put it first to avoid quadratic append.
        rdrs' = map snd capturing ++ noncapturing
      in (c { ctxtSubst = Just alphaSub }, rdrs')

-- | Check if RdrName is in FreeVars.
--
-- If so, return a pair of it and its new name (Right).
-- If not, return it unchanged (Left).
updateBinder :: FreeVars -> RdrName -> Either RdrName (RdrName, RdrName)
updateBinder fvs rdr
  | elemFVs rdr fvs = Right (rdr, renameBinder rdr fvs)
  | otherwise = Left rdr

-- | Given a RdrName, rename it to something not in given FreeVars.
--
--   x => x1
--   x1 => x2
--   x9 => x10
--
-- etc.
--
-- Only works on unqualified RdrNames. This is fine, as we only use this to
-- rename local binders.
renameBinder :: RdrName -> FreeVars -> RdrName
renameBinder rdr fvs = head
  [ rdr'
  | i <- [n..]
  , let rdr' = mkVarUnqual $ mkFastString $ baseName ++ show i
  , not $ rdr' `elemFVs` fvs
  ]
  where
    (ds, rest) = span isDigit $ reverse $ occNameString $ occName rdr

    baseName = reverse rest

    n :: Int
    n | null ds = 1
      | otherwise = read (reverse ds) + 1
