-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE DeriveGeneric #-}
module Cryptol.ModuleSystem.NamingEnv where

import Cryptol.ModuleSystem.Interface
import Cryptol.Parser.AST
import Cryptol.Parser.Names (namesP)
import Cryptol.Parser.Position
import qualified Cryptol.TypeCheck.AST as T
import Cryptol.Utils.PP
import Cryptol.Utils.Panic (panic)

import Data.Maybe (catMaybes)
import qualified Data.Map as Map

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

-- Name Locations --------------------------------------------------------------

data NameOrigin = Local (Located QName)
                | Imported QName
                  deriving (Show,Generic)

instance NFData NameOrigin

instance PP NameOrigin where
  ppPrec _ o = case o of
    Local lqn            -> pp lqn
    Imported (QName m n) -> pp n <+> trailer
      where
      trailer = case m of
        Just mn -> text "from module" <+> pp mn
        _       -> empty


-- Names -----------------------------------------------------------------------

data EName = EFromBind (Located QName)
           | EFromNewtype (Located QName)
           | EFromMod QName
             deriving (Show, Generic)

instance NFData EName

data TName = TFromParam QName
           | TFromSyn (Located QName)
           | TFromNewtype (Located QName)
           | TFromMod QName
             deriving (Show, Generic)

instance NFData TName

class HasQName a where
  qname  :: a -> QName
  origin :: a -> NameOrigin

instance HasQName TName where
  qname tn = case tn of
    TFromParam qn    -> qn
    TFromSyn lqn     -> thing lqn
    TFromNewtype lqn -> thing lqn
    TFromMod qn      -> qn

  origin tn = case tn of
    TFromParam qn    -> Local Located { srcRange = emptyRange, thing = qn }
    TFromSyn lqn     -> Local lqn
    TFromNewtype lqn -> Local lqn
    TFromMod qn      -> Imported qn

instance HasQName EName where
  qname en = case en of
    EFromBind lqn    -> thing lqn
    EFromNewtype lqn -> thing lqn
    EFromMod qn      -> qn

  origin en = case en of
    EFromBind lqn    -> Local lqn
    EFromNewtype lqn -> Local lqn
    EFromMod qn      -> Imported qn


-- Naming Environment ----------------------------------------------------------

-- XXX The fixity environment should be removed, and EName should include fixity
-- information.
data NamingEnv = NamingEnv { neExprs :: Map.Map QName [EName]
                             -- ^ Expr renaming environment
                           , neTypes :: Map.Map QName [TName]
                             -- ^ Type renaming environment
                           , neFixity:: Map.Map QName [Fixity]
                           } deriving (Show, Generic)

instance NFData NamingEnv

instance Monoid NamingEnv where
  mempty        =
    NamingEnv { neExprs  = Map.empty
              , neTypes  = Map.empty
              , neFixity = Map.empty }

  mappend l r   =
    NamingEnv { neExprs  = Map.unionWith (++) (neExprs  l) (neExprs  r)
              , neTypes  = Map.unionWith (++) (neTypes  l) (neTypes  r)
              , neFixity = Map.union          (neFixity l) (neFixity r) }

  mconcat envs  =
    NamingEnv { neExprs  = Map.unionsWith (++) (map neExprs  envs)
              , neTypes  = Map.unionsWith (++) (map neTypes  envs)
              , neFixity = Map.unions          (map neFixity envs) }

-- | Singleton type renaming environment.
singletonT :: QName -> TName -> NamingEnv
singletonT qn tn = mempty { neTypes = Map.singleton qn [tn] }

-- | Singleton expression renaming environment.
singletonE :: QName -> EName -> NamingEnv
singletonE qn en = mempty { neExprs = Map.singleton qn [en] }

-- | Like mappend, but when merging, prefer values on the lhs.
shadowing :: NamingEnv -> NamingEnv -> NamingEnv
shadowing l r = NamingEnv
  { neExprs  = Map.union (neExprs  l) (neExprs  r)
  , neTypes  = Map.union (neTypes  l) (neTypes  r)
  , neFixity = Map.union (neFixity l) (neFixity r) }

travNamingEnv :: Applicative f => (QName -> f QName) -> NamingEnv -> f NamingEnv
travNamingEnv f ne = NamingEnv <$> neExprs' <*> neTypes' <*> pure (neFixity ne)
  where
    neExprs' = traverse (traverse travE) (neExprs ne)
    neTypes' = traverse (traverse travT) (neTypes ne)
    travE en = case en of
      EFromBind lqn    -> EFromBind    <$> travLoc lqn
      EFromNewtype lqn -> EFromNewtype <$> travLoc lqn
      EFromMod qn      -> EFromMod     <$> f qn
    travT tn = case tn of
      TFromParam qn    -> TFromParam   <$> f qn
      TFromSyn lqn     -> TFromSyn     <$> travLoc lqn
      TFromNewtype lqn -> TFromNewtype <$> travLoc lqn
      TFromMod qn      -> TFromMod     <$> f qn
    travLoc loc = Located (srcRange loc) <$> f (thing loc)

-- | Things that define exported names.
class BindsNames a where
  namingEnv :: a -> NamingEnv

instance BindsNames NamingEnv where
  namingEnv = id

instance BindsNames a => BindsNames (Maybe a) where
  namingEnv = foldMap namingEnv

instance BindsNames a => BindsNames [a] where
  namingEnv = foldMap namingEnv

-- | Generate a type renaming environment from the parameters that are bound by
-- this schema.
instance BindsNames Schema where
  namingEnv (Forall ps _ _ _) = foldMap namingEnv ps

-- | Produce a naming environment from an interface file, that contains a
-- mapping only from unqualified names to qualified ones.
instance BindsNames Iface where
  namingEnv = namingEnv . ifPublic

-- | Translate a set of declarations from an interface into a naming
-- environment.
instance BindsNames IfaceDecls where
  namingEnv binds = mconcat [ types, newtypes, vars ]
    where

    types = mempty
      { neTypes = Map.map (map (TFromMod . ifTySynName)) (ifTySyns binds)
      }

    newtypes = mempty
      { neTypes = Map.map (map (TFromMod . T.ntName)) (ifNewtypes binds)
      , neExprs = Map.map (map (EFromMod . T.ntName)) (ifNewtypes binds)
      }

    vars = mempty
      { neExprs  = Map.map (map (EFromMod . ifDeclName)) (ifDecls binds)
      , neFixity = Map.fromList [ (n,fs) | ds <- Map.elems (ifDecls binds)
                                         , all ifDeclInfix ds
                                         , let fs = catMaybes (map ifDeclFixity ds)
                                               n  = ifDeclName (head ds) ]
      }


-- | Translate names bound by the patterns of a match into a renaming
-- environment.
instance BindsNames Match where
  namingEnv m = case m of
    Match p _  -> namingEnv p
    MatchLet b -> namingEnv b

instance BindsNames Bind where
  namingEnv b = singletonE (thing qn) (EFromBind qn) `mappend` fixity
    where
    qn = bName b

    fixity = case bFixity b of
               Just f  -> mempty { neFixity = Map.singleton (thing qn) [f] }
               Nothing -> mempty

-- | Generate the naming environment for a type parameter.
instance BindsNames TParam where
  namingEnv p = singletonT qn (TFromParam qn)
    where
    qn = mkUnqual (tpName p)

-- | Generate an expression renaming environment from a pattern.  This ignores
-- type parameters that can be bound by the pattern.
instance BindsNames Pattern where
  namingEnv p = foldMap unqualBind (namesP p)
    where
    unqualBind qn = singletonE (thing qn) (EFromBind qn)

-- | The naming environment for a single module.  This is the mapping from
-- unqualified internal names to fully qualified names.
instance BindsNames Module where
  namingEnv m = foldMap topDeclEnv (mDecls m)
    where
    topDeclEnv td = case td of
      Decl d      -> declEnv (tlValue d)
      TDNewtype n -> newtypeEnv (tlValue n)
      Include _   -> mempty

    qual = fmap (\qn -> mkQual (thing (mName m)) (unqual qn))

    qualBind ln = singletonE (thing ln) (EFromBind (qual ln))
    qualType ln = singletonT (thing ln) (TFromSyn (qual ln))

    declEnv d = case d of
      DSignature ns _sig    -> foldMap qualBind ns
      DPragma ns _p         -> foldMap qualBind ns
      DBind b               -> qualBind (bName b) `mappend` fixity b
      DPatBind _pat _e      -> panic "ModuleSystem" ["Unexpected pattern binding"]
      DFixity{}             -> panic "ModuleSystem" ["Unexpected fixity declaration"]
      DType (TySyn lqn _ _) -> qualType lqn
      DLocated d' _         -> declEnv d'

    fixity b =
      case bFixity b of
        Just f  -> mempty { neFixity = Map.singleton (thing (qual (bName b))) [f] }
        Nothing -> mempty

    newtypeEnv n = singletonT (thing qn) (TFromNewtype (qual qn))
         `mappend` singletonE (thing qn) (EFromNewtype (qual qn))
      where
      qn = nName n

-- | The naming environment for a single declaration, unqualified.  This is
-- meanat to be used for things like where clauses.
instance BindsNames Decl where
  namingEnv d = case d of
    DSignature ns _sig    -> foldMap qualBind ns
    DPragma ns _p         -> foldMap qualBind ns
    DBind b               -> qualBind (bName b)
    DPatBind _pat _e      -> panic "ModuleSystem" ["Unexpected pattern binding"]
    DFixity{}             -> panic "ModuleSystem" ["Unexpected fixity declaration"]
    DType (TySyn lqn _ _) -> qualType lqn
    DLocated d' _         -> namingEnv d'
    where
    qualBind ln = singletonE (thing ln) (EFromBind ln)
    qualType ln = singletonT (thing ln) (TFromSyn ln)


