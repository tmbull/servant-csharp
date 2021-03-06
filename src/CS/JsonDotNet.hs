{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
module CS.JsonDotNet ( GenerateCsConfig(..)
                     , def

                     , generateCsForAPI

                     , apiCsFrom
                     , enumCs
                     , classCs
                     , converterCs
                     , assemblyInfoCs
                     , projectCsproj
                     ) where


import Control.Arrow ((***), (&&&))
import Control.Lens hiding ((<.>))
import Control.Monad.Trans
import Control.Monad.Identity
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Char8 as BC (unpack)
import Data.Char (toUpper, toLower)
import qualified Data.HashMap.Strict.InsOrd as M
import Data.List (intercalate)
import Data.Maybe (fromJust)
import Data.Monoid ((<>))
import Data.Proxy
import Data.Swagger hiding (namespace)
import Data.Text as T (Text, unpack)
import Data.Time.Clock (UTCTime(..), getCurrentTime)
import Data.Time.Calendar (Day(..), toGregorian)
import Data.Word
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>),(<.>))
import Data.UUID.Types (toString, UUID)
import Data.UUID.V4 as UUID (nextRandom)
import Servant.Foreign
import Servant.Swagger
import Text.Heredoc

import CS.Common
import CS.JsonDotNet.Internal
import CS.JsonDotNet.Base

data GenerateCsConfig
    = GenerateCsConfig { namespace :: String
                       , classCsName :: String
                       , apiCsName :: String
                       , enumCsName :: String
                       , converterCsName :: String
                       , guid :: Maybe UUID
                       }

def :: GenerateCsConfig
def = GenerateCsConfig { namespace = "ServantClientAPI"
                       , classCsName = "Classes.cs"
                       , apiCsName = "API.cs"
                       , enumCsName = "Enum.cs"
                       , converterCsName = "JsonConverter.cs"
                       , guid = Nothing
                       }

--------------------------------------------------------------------------

-- | generate C# project
generateCsForAPI :: (HasSwagger api, HasForeign CSharp Text api,
                     GenerateList Text (Foreign Text api)) =>
                    GenerateCsConfig -> Proxy api -> IO ()
generateCsForAPI conf api = do
  let outDir = "gen" </> namespace conf
      swagger = toSwagger api
  createDirectoryIfMissing True $ outDir </> "Properties"
  writeFile (outDir </> "AssemblyInfo.cs") =<< assemblyInfoCs conf
  writeFile (outDir </> namespace conf <.> "csproj") =<< projectCsproj conf
  writeFile (outDir </> classCsName conf)
                $ runSwagger (classCs conf) swagger
  writeFile (outDir </> enumCsName conf)
                $ runSwagger enumCs swagger
  writeFile (outDir </> converterCsName conf)
                $ runSwagger (converterCs conf) swagger
  writeFile (outDir </> apiCsName conf)
                $ runSwagger (apiCsFrom conf api) swagger

--------------------------------------------------------------------------
retType :: Req Text -> String
retType = T.unpack . fromJust . view reqReturnType

uri :: Req Text -> String
uri req = T.unpack $ segmentsToText $ req^..reqUrl.path.traverse
    where
      segmentsToText :: [Segment f] -> Text
      segmentsToText = foldr segToText ""
      segToText :: Segment f -> Text -> Text
      segToText (Segment (Static s)) ss
          = "/" <> s^._PathSegment <> ss
      segToText (Segment (Cap s)) ss
          = "/{" <> prefix <> s^.argName._PathSegment <> "}" <> ss
      prefix = "_"

methodType :: Req Text -> String
methodType = capitalize . BC.unpack . view reqMethod
    where
      capitalize :: String -> String
      capitalize (c:cs) = toUpper c:map toLower cs

methodName :: Req Text -> String
methodName  = T.unpack . view (reqFuncName.camelCaseL)

paramDecl :: Req Text -> String
paramDecl = intercalate ", " . map help . paramInfos True
    where
      help :: (String, String) -> String
      help (t, n) = t<>" "<>(prefix<>n)
      prefix = "_"

paramArg :: Req Text -> String
paramArg = intercalate ", " . map help . paramInfos False
    where
      help :: (String, String) -> String
      help (_, n) = prefix<>n
      prefix = "_"

paramInfos :: Bool -> Req Text -> [(String, String)]
paramInfos b req = foldr (<>) mempty
                   $ map ($ req) [ captures
                                 , rqBody
                                 , queryparams'
                                 ]
    where
      queryparams' = map (help b) . queryparams
          where
            help True  = convToNullable *** (<>" = null")
            help False = convToNullable *** id
            -- TODO : more typeable
            convToNullable "int" = "int?"
            convToNullable "string" = "string"
            convToNullable "DateTime" = "DateTime?"
            convToNullable t = "Nullable<"<>t<>">"

queryparams :: Req Text -> [(String, String)]
queryparams req = map ((T.unpack . view argType
                       &&&
                        T.unpack . unPathSegment . view argName)
                      . view queryArgName)
                  $ req^..reqUrl.queryStr.traverse

captures :: Req Text -> [(String, String)]
captures req = map ((T.unpack . view argType &&& T.unpack . view argPath)
                    . captureArg)
               . filter isCapture
               $ req^.reqUrl.path

rqBody :: Req Text -> [(String, String)]
rqBody req = maybe [] (pure . (T.unpack &&& const jsonReqBodyName))
             $ req^.reqBody
    where
      jsonReqBodyName = "obj"

requestBodyExists :: Req Text -> Bool
requestBodyExists = not . null . rqBody

apiCsFrom :: (Monad m, HasForeign CSharp Text api,
              GenerateList Text (Foreign Text api)) =>
             GenerateCsConfig -> Proxy api -> SwagT m String
apiCsFrom conf api = do
  uas <- prims
  return [heredoc|/* generated by servant-csharp */
using Newtonsoft.Json;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;

#region type alias
$forall (n, t) <- uas
  using ${T.unpack n} = ${showCSharpOriginalType t};
#endregion

namespace ${namespace conf}
{
    class ServantClient : HttpClient
    {
        public ServantClient()
        {
            this.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        }
    }

    public class API
    {
        #region fields
        private string server;
        #endregion

        #region properties
        #endregion

        #region Constructor
        public API(string _server)
        {
            this.server = _server;
        }
        #endregion

        #region APIs
        $forall ep <- getEndpoints api
          $if retType ep /= "void"
            public async Task<${retType ep}> ${methodName ep}Async(${paramDecl ep})
          $else
            public async Task ${methodName ep}Async(${paramDecl ep})
          {
              var client = new ServantClient();
              var queryparams = new List<string> {
                  $forall (_, qp) <- queryparams ep
                    _${qp}.HasValue ? $"_${qp}={_${qp}.Value}" : null,
              }.Where(e => !string.IsNullOrEmpty(e));
              var qp= queryparams.Count() > 0 ? $"?{string.Join("&", queryparams)}" : "";
              $if requestBodyExists ep
                #if DEBUG
                var jsonObj = JsonConvert.SerializeObject(_obj, Formatting.Indented);
                #else
                var jsonObj = JsonConvert.SerializeObject(_obj);
                #endif
              $if requestBodyExists ep
                var res = await client.${methodType ep}Async($"{server}${uri ep}{qp}", new StringContent(jsonObj, Encoding.UTF8, "application/json"));
              $else
                var res = await client.${methodType ep}Async($"{server}${uri ep}{qp}");
              Debug.WriteLine($">>> {res.RequestMessage}");
              $if requestBodyExists ep
                Debug.WriteLine($"-----");
                Debug.WriteLine(jsonObj);
                Debug.WriteLine($"-----");
              Debug.WriteLine($"<<< {(int)res.StatusCode} {res.ReasonPhrase}");
              var content = await res.Content.ReadAsStringAsync();
              Debug.WriteLine($"<<< {content}");
              $if retType ep /= "void"
                return JsonConvert.DeserializeObject<${retType ep}>(content);
              $else
                JsonConvert.DeserializeObject(content);
         }
          public ${retType ep} ${methodName ep}(${paramDecl ep})
          {
              $if retType ep /= "void"
                Task<${retType ep}> t = ${methodName ep}Async(${paramArg ep});
                return t.GetAwaiter().GetResult();
              $else
                Task t = ${methodName ep}Async(${paramArg ep});
                t.GetAwaiter().GetResult();
          }
        #endregion
    }
}
|]

--------------------------------------------------------------------------

defs :: Monad m => SwagT m [(Text, Schema)]
defs = mkSwag (M.toList . _swaggerDefinitions)

pathitems :: Monad m => SwagT m [(FilePath, PathItem)]
pathitems = mkSwag (M.toList . _swaggerPaths)

convProperty :: Monad m => ParamName -> Referenced Schema -> Bool
             -> SwagT m (ParamName, FieldType)
convProperty pname rs req
    = if req
      then convProp pname rs
      else do
        (n, f) <- convProp pname rs
        return (n, FNullable f)
    where
      convProp :: Monad m
                  => ParamName
                      -> Referenced Schema
                      -> SwagT m (ParamName, FieldType)
      convProp n (Ref (Reference s)) = convRef n s
      convProp n (Inline s) = convert (n, s)

convRef :: Monad m
           => ParamName -> Text -> SwagT m (ParamName, FieldType)
convRef pname tname = do
  fs <- enums <> prims <> models
  case lookup tname fs of
    Just ftype -> return $ (pname, conv ftype)
    Nothing -> error $ T.unpack $ "not found " <> pname
  where
    conv :: FieldType -> FieldType
    conv f | isFEnum f = FRefEnum tname
           | isFPrim f = FRefPrim tname f
           | isFObj  f = FRefObject tname
  
convObject :: Monad m => (Text, Schema) -> SwagT m (Text, FieldType)
convObject (name, s) = do
  return . (name,) . FObject name =<< fields
    where
      fields :: Monad m => SwagT m [(ParamName, FieldType)]
      fields = mapM (\(p, s) -> (convProperty p s (isReq p))) props
      props :: [(ParamName, Referenced Schema)]
      props = M.toList (_schemaProperties s)
      isReq :: ParamName -> Bool
      isReq pname = pname `elem` reqs
      reqs :: [ParamName]
      reqs = _schemaRequired s

convert :: Monad m => (Text, Schema) -> SwagT m (Text, FieldType)
convert (name, s) = do
  if not $ null enums'
  then return $ (name, FEnum name enums')
  else case type' of
         SwaggerString -> maybe (return (name, FString))
                                convByFormat
                                format'
         SwaggerInteger -> return (name, FInteger)
         SwaggerNumber -> return (name, FNumber)
         SwaggerBoolean -> return (name, FBool)
         SwaggerArray -> maybe (error "fail to convert SwaggerArray")
                               convByItemType
                               items'
         SwaggerNull -> error "convert don't support SwaggerNull yet"
         SwaggerObject -> convObject (name, s)
    where
      param' = _schemaParamSchema s
      items' = _paramSchemaItems param'
      type' = _paramSchemaType param'
      enums' = maybe [] id $ _paramSchemaEnum param'
      format' = _paramSchemaFormat param'
      convByFormat :: Monad m => Text -> SwagT m (Text, FieldType)
      convByFormat "date" = return (name, FDay)
      convByFormat "yyyy-mm-ddThh:MM:ssZ" = return (name, FUTCTime)
      convByItemType :: Monad m
                        => SwaggerItems t -> SwagT m (Text, FieldType)
      convByItemType (SwaggerItemsObject (Ref (Reference s))) = do
                      (n, t) <- convRef name s
                      return (n, FList t)
      convByItemType (SwaggerItemsPrimitive _ _)
          = error "don't support SwaggerItemsPrimitive yet"
      convByItemType (SwaggerItemsArray _)
          = error "don't support SwaggerItemsArray yet"

enums :: Monad m => SwagT m [(Text, FieldType)]
enums = filterM (return.isFEnum.snd) =<< mapM convert =<< defs

prims :: Monad m => SwagT m [(Text, FieldType)]
prims = filterM (return.isFPrim.snd) =<< mapM convert =<< defs

models :: Monad m => SwagT m [(Text, FieldType)]
models = filterM (return.isFObj.snd) =<< mapM convert =<< defs
enumCs :: Monad m => SwagT m String
enumCs = do
  es <- mapM (return.snd) =<< enums
  return [heredoc|/* generated by servant-csharp */
namespace ServantClientBook
{
    $forall FEnum name cs <- es
      #region ${T.unpack name}
      public enum ${T.unpack name}
      {
          $forall String c <- cs
            ${T.unpack c},
      }
      #endregion
}
|]

showCSharpOriginalType :: FieldType -> String
showCSharpOriginalType FInteger = "System.Int64"
showCSharpOriginalType FNumber = "System.Double"
showCSharpOriginalType FString = "System.String"
showCSharpOriginalType FDay = "System.DateTime"
showCSharpOriginalType FUTCTime = "System.DateTime"
showCSharpOriginalType _ = error "don't support this type."

show' :: FieldType -> String
show' FInteger = "int"
show' FNumber = "double"
show' FString = "string"
show' FBool = "bool"
show' FDay = "DateTime"
show' FUTCTime = "DateTime"
show' (FEnum name _) = T.unpack name
show' (FObject name _) = T.unpack name
show' (FList t) = "List<" <> show' t <> ">"
show' (FNullable t) = case nullable t of
                        CVal -> show' t <> "?"
                        CRef -> show' t
                        CSt  -> "Nullable<" <> show' t <> ">"
show' (FRefObject name) = T.unpack name
show' (FRefEnum name) = T.unpack name
show' (FRefPrim name _) = T.unpack name

converterType :: FieldType -> ConverterType
converterType FDay = DayConv
converterType (FRefPrim _ FDay) = DayConv
converterType (FEnum _ _) = EnumConv
converterType (FRefEnum _) = EnumConv
converterType (FNullable t) = converterType t
converterType (FList t) = case converterType t of
                            DayConv -> ItemConv DayConv
                            EnumConv -> ItemConv EnumConv
                            t' -> t'
converterType _ = NoConv


classCs :: Monad m => GenerateCsConfig -> SwagT m String
classCs conf = do
  ps <- prims
  ms <- models
  return [heredoc|/* generated by servant-csharp */
using Newtonsoft.Json;
using Newtonsoft.Json.Converters;
using System;
using System.Collections.Generic;

#region type alias
$forall (n, t) <- ps
  using ${T.unpack n} = ${showCSharpOriginalType t};
#endregion

namespace ${namespace conf}
{
    $forall (_, FObject name' fields) <- ms
      $let name = T.unpack name'
        #region ${name}
        [JsonObject("${name}")]
        public class ${name}
        {
            $forall (fname', ftype) <- fields
              $let fname = T.unpack fname'
                $case converterType ftype
                  $of DayConv
                    [JsonProperty(PropertyName = "${fname}")]
                    [JsonConverter(typeof(DayConverter))]
                  $of ItemConv DayConv
                    [JsonProperty(PropertyName = "${fname}", ItemConverterType = typeof(DayConverter))]
                  $of EnumConv
                    [JsonProperty(PropertyName = "${fname}")]
                    [JsonConverter(typeof(StringEnumConverter))]
                  $of ItemConv EnumConv
                    [JsonProperty(PropertyName = "${fname}", ItemConverterType = typeof(StringEnumConverter))]
                  $of _
                    [JsonProperty(PropertyName = "${fname}")]
                public ${show' ftype} ${fname} { get; set; }
        }
        #endregion
}
|]

converterCs :: Monad m => GenerateCsConfig -> SwagT m String
converterCs conf = return [heredoc|/* generated by servant-csharp */
using Newtonsoft.Json;
using System;

namespace ${namespace conf}
{
    public class DayConverter : JsonConverter
    {
        public override bool CanConvert(Type objectType)
        {
            return objectType == typeof(DateTime);
        }

        public override object ReadJson(JsonReader reader, Type objectType, object existingValue, JsonSerializer serializer)
        {
            return DateTime.Parse((string)reader.Value);
        }

        public override void WriteJson(JsonWriter writer, object value, JsonSerializer serializer)
        {
            DateTime d = (DateTime)value;
            writer.WriteValue(d.ToString("yyyy-MM-dd"));
        }
    }
}
|]

assemblyInfoCs :: GenerateCsConfig -> IO String
assemblyInfoCs conf = do
  (year, _, _) <- fmap (toGregorian . utctDay) getCurrentTime
  guid' <- maybe UUID.nextRandom return $ guid conf
  return [heredoc|
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("${namespace conf}")]
[assembly: AssemblyDescription("")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("")]
[assembly: AssemblyProduct("${namespace conf}")]
[assembly: AssemblyCopyright("Copyright ${show year}")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyCulture("")]

[assembly: ComVisible(false)]

[assembly: Guid("${toString guid'}")]

// [assembly: AssemblyVersion("1.0.*")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
|]

projectCsproj :: GenerateCsConfig -> IO String
projectCsproj conf = do
  guid' <- maybe ((map toUpper . toString) <$> UUID.nextRandom)
                 (return . toString)
                 $ guid conf
  return [heredoc|<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="14.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props" Condition="Exists('$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props')" />
  <PropertyGroup>
    <Configuration Condition=" '$(Configuration)' == '' ">Debug</Configuration>
    <Platform Condition=" '$(Platform)' == '' ">AnyCPU</Platform>
    <ProjectGuid>{${guid'}}</ProjectGuid>
    <OutputType>Library</OutputType>
    <AppDesignerFolder>Properties</AppDesignerFolder>
    <RootNamespace>${namespace conf}</RootNamespace>
    <AssemblyName>${namespace conf}</AssemblyName>
    <TargetFrameworkVersion>v4.5.2</TargetFrameworkVersion>
    <FileAlignment>512</FileAlignment>
  </PropertyGroup>
  <PropertyGroup Condition=" '$(Configuration)|$(Platform)' == 'Debug|AnyCPU' ">
    <DebugSymbols>true</DebugSymbols>
    <DebugType>full</DebugType>
    <Optimize>false</Optimize>
    <OutputPath>bin\Debug\</OutputPath>
    <DefineConstants>DEBUG;TRACE</DefineConstants>
    <ErrorReport>prompt</ErrorReport>
    <WarningLevel>4</WarningLevel>
  </PropertyGroup>
  <PropertyGroup Condition=" '$(Configuration)|$(Platform)' == 'Release|AnyCPU' ">
    <DebugType>pdbonly</DebugType>
    <Optimize>true</Optimize>
    <OutputPath>bin\Release\</OutputPath>
    <DefineConstants>TRACE</DefineConstants>
    <ErrorReport>prompt</ErrorReport>
    <WarningLevel>4</WarningLevel>
  </PropertyGroup>
  <ItemGroup>
    <Reference Include="Newtonsoft.Json, Version=4.5.0.0, Culture=neutral, PublicKeyToken=30ad4fe6b2a6aeed, processorArchitecture=MSIL" />
    <Reference Include="System" />
    <Reference Include="System.Core" />
    <Reference Include="System.Xml.Linq" />
    <Reference Include="System.Data.DataSetExtensions" />
    <Reference Include="Microsoft.CSharp" />
    <Reference Include="System.Data" />
    <Reference Include="System.Net.Http" />
    <Reference Include="System.Xml" />
  </ItemGroup>
  <ItemGroup>
    <Compile Include="${apiCsName conf}" />
    <Compile Include="${converterCsName conf}" />
    <Compile Include="${classCsName conf}" />
    <Compile Include="${enumCsName conf}" />
    <Compile Include="Properties\AssemblyInfo.cs" />
  </ItemGroup>
  <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
  <!-- To modify your build process, add your task inside one of the targets below and uncomment it. 
       Other similar extension points exist, see Microsoft.Common.targets.
  <Target Name="BeforeBuild">
  </Target>
  <Target Name="AfterBuild">
  </Target>
  -->
</Project>|]
