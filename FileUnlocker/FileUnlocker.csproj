<Project Sdk="Microsoft.NET.Sdk.WindowsDesktop">

  <PropertyGroup>
    <OutputType>WinExe</OutputType>

    <!-- Target .NET 10 desktop -->
    <TargetFramework>net10.0-windows</TargetFramework>

    <!-- Needed for WinForms UI -->
    <UseWindowsForms>true</UseWindowsForms>

    <Company>NA</Company>
    <Authors>Marian Pekár</Authors>
    <PackageRequireLicenseAcceptance>false</PackageRequireLicenseAcceptance>
    <Description>A tool that unlocks a file by gathering and closing processes that use it.</Description>
    <Version>1.1.0</Version>
    <PackageProjectUrl>https://github.com/marianpekar/file-unlocker-for-windows/releases</PackageProjectUrl>
    <RepositoryUrl>https://github.com/marianpekar/file-unlocker-for-windows</RepositoryUrl>
  </PropertyGroup>

  <PropertyGroup Condition="'$(Configuration)|$(Platform)'=='Release|AnyCPU'">
    <PlatformTarget>x64</PlatformTarget>
    <AllowUnsafeBlocks>false</AllowUnsafeBlocks>
  </PropertyGroup>

  <Target Name="PostBuild" AfterTargets="PostBuildEvent">
    <Exec Command="copy /y &quot;$(ProjectDir)install.bat&quot; &quot;$(TargetDir)install.bat&quot;&#xD;&#xA;copy /y &quot;$(ProjectDir)remove.bat&quot; &quot;$(TargetDir)remove.bat&quot;&#xD;&#xA;copy /y &quot;$(ProjectDir)key.ico&quot; &quot;$(TargetDir)key.ico&quot;&#xD;&#xA;" />
  </Target>

  <ItemGroup>
    <None Remove="icon.png" />
    <None Remove="icon.png" />
  </ItemGroup>

</Project>
