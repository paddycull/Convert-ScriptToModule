<#
.SYNOPSIS
Function to convert a ps1 file with several separate functions into a PowerShell module.

.DESCRIPTION
This function is designed to convert ps1 files with multiple functions, into a full PowerShell module. Each ps1 file can contain multiple functions, the script will divide them out into separate ps1 files within the module.
It creates the proper module directories and layout, generates the psm1 file with the required parameters and settings, and can optionally make some functions private , so they are only visible to other functions in the module and not to the user of the module. 
It also detects ArgumentCompleters, and inserts them into an initialisation file so they are loaded as needed. 

.EXAMPLE
Convert-ScriptToModule -ScriptPath "C:\PSscripts\AllInOne.ps1" -ModuleName TestModule -ModulePath "C:\PSmodules"

This example will read the AllInOne.ps1 file and extract all functions or argument completers, as well as any #require tags to determine RequiredModules. 
- The module directory will be created at "C:\PSmodules\TestModule"
- Each function will be placed in it's own self-named .ps1 file within a "Public" folder in the module directory
- Argument completers will be placed within \Init\LoadArgumentCompleters.ps1
- The psd1 and psm1 files will be generated, with the required parameters such as any RequiredModules, and FunctionsToExport

.EXAMPLE
Convert-ScriptToModule -ScriptPath "C:\PSscripts\AllInOne.ps1", "C:\PSscripts\Get-Example.ps1"  -ModuleName TestModule -ModulePath "C:\PSmodules" -PrivateFunctions Get-PsExample

This example will read both given files for any functions or argument completers and output it into a single module called TestModule. It will do the same steps as Example 1, except the function "Get-PsExample" will be created as a private function and placed in the \Private directory


.NOTES
For function names to be discovered correctly, the line with the function declaration needs to have the opening curly bracket on the same line, or on the line immediately after it. 
The closing bracket for the function needs to be at the very start of it's own line, without any spaces before it. So make sure there is no closing brackets at the very start of any line UNLESS it's a function ending.
A handy way to make your script adhere to these rules is to open it in VSCode and press Shift+Alt+F - this will format the document to best standards. 

e.g;
function Get-Example {
    ...
} #no spaces before this curly bracket

OR 

function Get-Example
{
...
} #no spaces before this curly bracket
#>
function Convert-ScriptToModule {
    param (
        # Path to the script(s) containing all the modules.
        [Parameter(Mandatory)]
        [string[]]$ScriptPath,

        # Name of the new module.
        [Parameter(Mandatory)]
        [string]$ModuleName,

        # Directory to output the new module to.
        [Parameter(Mandatory)]
        [string]$ModulePath,

        # Names of the functions to be made Private for the module - functions are made public by default.
        [string[]] $PrivateFunctions
    )

    $FullModulePath = "$ModulePath\$ModuleName"
    $PublicFunctionPath = "$FullModulePath\Public"
    $PrivateFunctionPath = "$FullModulePath\Private"
    $InitFunctionPath = "$FullModulePath\Init"
    

    mkdir $PublicFunctionPath -Force
    mkdir $PrivateFunctionPath -Force

    $FunctionList = @()
    $ScriptFunction = @()

    foreach ($script in $ScriptPath) {
        Write-Verbose "Reading $script"
        try {
            $ScriptFileContents = Get-Content $script
        }
        catch {
            Write-Warning "Could not read file $script"
            continue
        }

        $lineIndex = 0
        foreach($line in $ScriptFileContents) {
            $nextLineIndex = $lineIndex + 1
            
            #Extract the required modules and versions
            if($line -like '#requires*') {
                if($line -like '*-modules*') {
                    $RequiredModules = $line -replace '#Requires -Modules '
                }
                if($line -like '*-version*') {
                    $RequiredVersion = $line -replace '#Requires -Version '
                }
            }

            #If a function name is found we extract the name.
            if($line -like 'function*{*') {
                #Regex the function name
                $pattern = "function(.*?){"
                $FunctionName = ([regex]::Match($line,$pattern).Groups[1].Value).Trim()
                $FunctionList += $FunctionName
                Write-Verbose "Found $FunctionName"
            }
            # If a function declaration is found and the following line is an open curly bracket, we extract the name.
            elseif($line -like 'function*' -and $ScriptFileContents[$nextLineIndex] -like '{*') {
                $FunctionName = $line -replace 'function '
                $FunctionList += $FunctionName
                Write-Verbose "Found $FunctionName"
            }

            if($line -like 'Register-ArgumentCompleter*') {
                if(!(Test-Path $InitFunctionPath)) {
                    mkdir $InitFunctionPath -Force
                }
                $ArgumentCompleter = $true
                Write-Verbose "Found $line"        
            }

            if($line -ne '') {
                $ScriptFunction += $line
            }

            if($line -like '}*') {
                if($ArgumentCompleter) {
                    Write-Verbose "Adding argument completer to $InitFunctionPath\LoadArgumentCompleters.ps1"
                    $ScriptFunction | Out-File "$InitFunctionPath\LoadArgumentCompleters.ps1" -Append
                    $ArgumentCompleter = $false
                }
                elseif($FunctionName -in $PrivateFunctions) {
                    Write-Verbose "Adding $FunctionName to $PrivateFunctionPath\${FunctionName}.ps1"
                    $ScriptFunction | Out-File "$PrivateFunctionPath\${FunctionName}.ps1"
                }
                else {
                    Write-Verbose "Adding $FunctionName to $PublicFunctionPath\${FunctionName}.ps1"
                    $ScriptFunction | Out-File "$PublicFunctionPath\${FunctionName}.ps1"
                }

                $ScriptFunction = @() #empty the current function variable
            }

            $lineIndex++
        }
    }

    #Create the psm file to import the functions
    $PsmContents = @'
#Get public and private function definition files.

$Public  = @( Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue )

$Private = @( Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue )

foreach($import in @($Public + $Private)) {
    try {
        . $import.fullname
    }
    catch{
        Write-Error -Message "Failed to import function $($import.fullname): $_"
    }
}

Export-ModuleMember -Function $Public.Basename
'@
    if(Test-Path $InitFunctionPath) {
        $PsmContents += @'


#region Initialization
Get-ChildItem -Path "$PSScriptRoot/Init" | ForEach-Object {
    Write-Verbose "Initializing module: [$($_.Name)]"
    . $_.FullName
}
'@
    }

    $PsmContents | Out-File "$FullModulePath/$ModuleName.psm1"

    $FunctionsToExport = $FunctionList | Where-Object {$PrivateFunctions -NotContains $_}

    #Create the mnanifest file
    New-ModuleManifest -Path "$FullModulePath/$ModuleName.psd1" -RootModule "$ModuleName.psm1" -PowerShellVersion $RequiredVersion -RequiredModules $RequiredModules -FunctionsToExport $FunctionsToExport
}
