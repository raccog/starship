#!/usr/bin/env pwsh

function global:prompt {
        
    function Get-Cwd {
        $cwd = Get-Location
        $provider_prefix = "$($cwd.Provider.ModuleName)\$($cwd.Provider.Name)::"
        return @{
            # Resolve the actual/physical path
            # NOTE: ProviderPath is only a physical filesystem path for the "FileSystem" provider
            # E.g. `Dev:\` -> `C:\Users\Joe Bloggs\Dev\`
            Path = $cwd.ProviderPath;
            # Resolve the provider-logical path 
            # NOTE: Attempt to trim any "provider prefix" from the path string.
            # E.g. `Microsoft.PowerShell.Core\FileSystem::Dev:\` -> `Dev:\`
            LogicalPath =
                if ($cwd.Path.StartsWith($provider_prefix)) {
                    $cwd.Path.Substring($provider_prefix.Length)
                } else {
                    $cwd.Path
                };
        }
    }

    function Invoke-Native {
        param($Executable, $Arguments)
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList $Executable -Property @{
            StandardOutputEncoding = [System.Text.Encoding]::UTF8;
            RedirectStandardOutput = $true;
            RedirectStandardError = $true;
            CreateNoWindow = $true;
            UseShellExecute = $false;
        };
        if ($startInfo.ArgumentList.Add) {
            # PowerShell 6+ uses .NET 5+ and supports the ArgumentList property
            # which bypasses the need for manually escaping the argument list into
            # a command string.
            foreach ($arg in $Arguments) {
                $startInfo.ArgumentList.Add($arg);
            }
        }
        else {
            # Build an arguments string which follows the C++ command-line argument quoting rules
            # See: https://docs.microsoft.com/en-us/previous-versions//17w5ykft(v=vs.85)?redirectedfrom=MSDN
            $escaped = $Arguments | ForEach-Object {
                $s = $_ -Replace '(\\+)"','$1$1"'; # Escape backslash chains immediately preceding quote marks.
                $s = $s -Replace '(\\+)$','$1$1';  # Escape backslash chains immediately preceding the end of the string.
                $s = $s -Replace '"','\"';         # Escape quote marks.
                "`"$s`""                           # Quote the argument.
            }
            $startInfo.Arguments = $escaped -Join ' ';
        }
        $process = [System.Diagnostics.Process]::Start($startInfo)

        # stderr isn't displayed with this style of invocation
        # Manually write it to console
        $stderr = $process.StandardError.ReadToEnd().Trim()
        if ($stderr -ne '') {
            # Write-Error doesn't work here
            $host.ui.WriteErrorLine($stderr)
        }

        $process.StandardOutput.ReadToEnd();
    }

    $origDollarQuestion = $global:?
    $origLastExitCode = $global:LASTEXITCODE

    # Invoke precmd, if specified
    try {
        if (Test-Path function:Invoke-Starship-PreCommand) {
            Invoke-Starship-PreCommand
        }
    } catch {}

    # @ makes sure the result is an array even if single or no values are returned
    $jobs = @(Get-Job | Where-Object { $_.State -eq 'Running' }).Count
    
    $cwd = Get-Cwd
    $arguments = @(
        "prompt"
        "--path=$($cwd.Path)",
        "--logical-path=$($cwd.LogicalPath)",
        "--terminal-width=$($Host.UI.RawUI.WindowSize.Width)",
        "--jobs=$($jobs)"
    )
    
    # Whe start from the premise that the command executed correctly, which covers also the fresh console.
    $lastExitCodeForPrompt = 0
    if ($lastCmd = Get-History -Count 1) {
        # In case we have a False on the Dollar hook, we know there's an error.
        if (-not $origDollarQuestion) {
            # We retrieve the InvocationInfo from the most recent error using $error[0]
            $lastCmdletError = try { $error[0] |  Where-Object { $_ -ne $null } | Select-Object -ExpandProperty InvocationInfo } catch { $null }
            # We check if the last command executed matches the line that caused the last error, in which case we know
            # it was an internal Powershell command, otherwise, there MUST be an error code.
            $lastExitCodeForPrompt = if ($null -ne $lastCmdletError -and $lastCmd.CommandLine -eq $lastCmdletError.Line) { 1 } else { $origLastExitCode }
        }
        $duration = [math]::Round(($lastCmd.EndExecutionTime - $lastCmd.StartExecutionTime).TotalMilliseconds)
        
        $arguments += "--cmd-duration=$($duration)"
    }

    $arguments += "--status=$($lastExitCodeForPrompt)"

    # Invoke Starship
    Invoke-Native -Executable ::STARSHIP:: -Arguments $arguments

    # Propagate the original $LASTEXITCODE from before the prompt function was invoked.
    $global:LASTEXITCODE = $origLastExitCode

    # Propagate the original $? automatic variable value from before the prompt function was invoked.
    #
    # $? is a read-only or constant variable so we can't directly override it.
    # In order to propagate up its original boolean value we will take an action
    # which will produce the desired value.
    #
    # This has to be the very last thing that happens in the prompt function
    # since every PowerShell command sets the $? variable.
    if ($global:? -ne $origDollarQuestion) {
        if ($origDollarQuestion) {
             # Simple command which will execute successfully and set $? = True without any other side affects.
            1+1
        } else {
            # Write-Error will set $? to False.
            # ErrorAction Ignore will prevent the error from being added to the $Error collection.
            Write-Error '' -ErrorAction 'Ignore'
        }
    }

}

# Disable virtualenv prompt, it breaks starship
$ENV:VIRTUAL_ENV_DISABLE_PROMPT=1

$ENV:STARSHIP_SHELL = "powershell"

# Set up the session key that will be used to store logs
$ENV:STARSHIP_SESSION_KEY = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
