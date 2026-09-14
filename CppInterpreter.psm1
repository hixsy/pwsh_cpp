Set-StrictMode -Version Latest

$script:CppVars = @{}

function Convert-CppStringLiteral {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $result = $Value
    $result = $result -replace '\\0', ([string][char]0)
    $result = $result -replace '\\n', "`n"
    $result = $result -replace '\\r', "`r"
    $result = $result -replace '\\t', "`t"
    $result = $result -replace '\\"', '"'
    $result = $result -replace "\\'", "'"
    $result = $result -replace '\\\\', '\'

    return $result
}

function Get-CppCStringValue {
    param(
        [Parameter(Mandatory)]
        [string]$Expression
    )

    $expr = $Expression.Trim()

    if ($expr -match '^"(.*)"$') {
        return Convert-CppStringLiteral $matches[1]
    }

    if ($script:CppVars.ContainsKey($expr)) {
        return [string]$script:CppVars[$expr]
    }

    throw "Expected C string expression, got: $Expression"
}

function Split-CppArguments {
    param(
        [Parameter(Mandatory)]
        [string]$Arguments
    )

    $result = @()
    $current = ""
    $inString = $false
    $inChar = $false
    $escape = $false
    $depth = 0

    for ($i = 0; $i -lt $Arguments.Length; $i++) {
        $c = $Arguments[$i]

        if ($escape) {
            $current += $c
            $escape = $false
            continue
        }

        if (($inString -or $inChar) -and $c -eq '\') {
            $current += $c
            $escape = $true
            continue
        }

        if (-not $inChar -and $c -eq '"') {
            $inString = -not $inString
            $current += $c
            continue
        }

        if (-not $inString -and $c -eq "'") {
            $inChar = -not $inChar
            $current += $c
            continue
        }

        if (-not $inString -and -not $inChar) {
            if ($c -eq '(') {
                $depth++
            }
            elseif ($c -eq ')') {
                $depth--
            }
            elseif ($c -eq ',' -and $depth -eq 0) {
                $result += $current.Trim()
                $current = ""
                continue
            }
        }

        $current += $c
    }

    if ($current.Trim().Length -gt 0) {
        $result += $current.Trim()
    }

    return $result
}

function Invoke-CppStrlen {
    param(
        [Parameter(Mandatory)]
        [string]$Argument
    )

    $value = Get-CppCStringValue $Argument

    $nul = $value.IndexOf([char]0)

    if ($nul -ge 0) {
        return [uint64]$nul
    }

    return [uint64]$value.Length
}

function Invoke-CppStrcmp {
    param(
        [Parameter(Mandatory)]
        [string]$LeftArgument,

        [Parameter(Mandatory)]
        [string]$RightArgument
    )

    $left = Get-CppCStringValue $LeftArgument
    $right = Get-CppCStringValue $RightArgument

    $leftNul = $left.IndexOf([char]0)
    if ($leftNul -ge 0) {
        $left = $left.Substring(0, $leftNul)
    }

    $rightNul = $right.IndexOf([char]0)
    if ($rightNul -ge 0) {
        $right = $right.Substring(0, $rightNul)
    }

    $count = [Math]::Min($left.Length, $right.Length)

    for ($i = 0; $i -lt $count; $i++) {
        $a = [int][char]$left[$i]
        $b = [int][char]$right[$i]

        if ($a -lt $b) {
            return -1
        }

        if ($a -gt $b) {
            return 1
        }
    }

    if ($left.Length -lt $right.Length) {
        return -1
    }

    if ($left.Length -gt $right.Length) {
        return 1
    }

    return 0
}

function Resolve-CppStandardFunctions {
    param(
        [Parameter(Mandatory)]
        [string]$Expression
    )

    $expr = $Expression

    # Resolve innermost supported calls first.
    while ($expr -match '(?:std::)?(strlen|strcmp)\s*\(([^()]*)\)') {
        $wholeCall = $matches[0]
        $function = $matches[1]
        $arguments = $matches[2]

        switch ($function) {
            'strlen' {
                $args = @(Split-CppArguments $arguments)

                if ($args.Count -ne 1) {
                    throw "strlen requires exactly 1 argument."
                }

                $result = Invoke-CppStrlen $args[0]
            }

            'strcmp' {
                $args = @(Split-CppArguments $arguments)

                if ($args.Count -ne 2) {
                    throw "strcmp requires exactly 2 arguments."
                }

                $result = Invoke-CppStrcmp `
                    -LeftArgument $args[0] `
                    -RightArgument $args[1]
            }
        }

        $position = $expr.IndexOf($wholeCall)

        if ($position -lt 0) {
            break
        }

        $expr =
            $expr.Substring(0, $position) +
            [string]$result +
            $expr.Substring($position + $wholeCall.Length)
    }

    return $expr
}

function Convert-CppExpression {
    param(
        [Parameter(Mandatory)]
        [string]$Expression
    )

    $expr = $Expression.Trim()

    $expr = Resolve-CppStandardFunctions $expr

    # Character literals -> integer character codes.
    $expr = [regex]::Replace(
        $expr,
        "'([^'\\]|\\.)'",
        {
            param($m)

            $text = $m.Groups[1].Value

            if ($text.StartsWith('\')) {
                switch ($text) {
                    '\n' { return [string][int][char]"`n" }
                    '\r' { return [string][int][char]"`r" }
                    '\t' { return [string][int][char]"`t" }
                    '\0' { return '0' }
                    "\\'" { return [string][int][char]"'" }
                    '\\' { return [string][int][char]'\' }
                    default { throw "Unsupported C++ character escape: $text" }
                }
            }

            return [string][int][char]$text
        }
    )

    $expr = $expr -replace '\btrue\b', '$true'
    $expr = $expr -replace '\bfalse\b', '$false'

    $expr = $expr -replace '&&', ' -and '
    $expr = $expr -replace '\|\|', ' -or '

    $expr = $expr -replace '!=', ' -ne '
    $expr = $expr -replace '==', ' -eq '
    $expr = $expr -replace '>=', ' -ge '
    $expr = $expr -replace '<=', ' -le '
    $expr = $expr -replace '>', ' -gt '
    $expr = $expr -replace '<', ' -lt '

    $expr = $expr -replace '(?<![=!])!(?!=)', ' -not '

    #
    # Replace known C++ variables with literal PowerShell values.
    # This avoids relying on Invoke-Expression to resolve module-scope
    # variables such as $script:CppVars['x'].
    #
    foreach ($name in ($script:CppVars.Keys | Sort-Object Length -Descending)) {
        $escaped = [regex]::Escape($name)
        $value = $script:CppVars[$name]

        if ($value -is [bool]) {
            if ($value) {
                $literal = '$true'
            }
            else {
                $literal = '$false'
            }
        }
        elseif ($value -is [char]) {
            $literal = [string][int][char]$value
        }
        elseif ($value -is [string]) {
            $escapedString = ([string]$value).Replace("'", "''")
            $literal = "'" + $escapedString + "'"
        }
        elseif (
            $value -is [byte] -or
            $value -is [sbyte] -or
            $value -is [int16] -or
            $value -is [uint16] -or
            $value -is [int32] -or
            $value -is [uint32] -or
            $value -is [int64] -or
            $value -is [uint64] -or
            $value -is [single] -or
            $value -is [double] -or
            $value -is [decimal]
        ) {
            $literal = [Convert]::ToString(
                $value,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        else {
            $escapedString = ([string]$value).Replace("'", "''")
            $literal = "'" + $escapedString + "'"
        }

        $pattern = "\b$escaped\b"

        $expr = [regex]::Replace(
            $expr,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                return $literal
            }
        )
    }

    return $expr
}

function Invoke-CppExpression {
    param(
        [Parameter(Mandatory)]
        [string]$Expression
    )

    $expr = Convert-CppExpression $Expression

    try {
        return Invoke-Expression $expr
    }
    catch {
        throw "Could not evaluate C++ expression: $Expression`nConverted to: $expr`n$($_.Exception.Message)"
    }
}

function Format-CppTraceValue {
    param(
        [Parameter(Mandatory)]
        [string]$Expression
    )

    $expr = $Expression.Trim()

    if ($script:CppVars.ContainsKey($expr)) {
        $value = $script:CppVars[$expr]

        if ($value -is [bool]) {
            if ($value) {
                return 'true'
            }

            return 'false'
        }

        if ($value -is [char]) {
            return "'" + [string]$value + "'"
        }

        if ($value -is [string]) {
            $escaped = ([string]$value).Replace('\', '\\').Replace('"', '\"')
            return '"' + $escaped + '"'
        }

        return [Convert]::ToString(
            $value,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    if ($expr -match '^".*"$') {
        return $expr
    }

    if ($expr -match "^'.*'$") {
        return $expr
    }

    try {
        $value = Invoke-CppExpression $expr

        if ($value -is [bool]) {
            if ($value) {
                return 'true'
            }

            return 'false'
        }

        if ($value -is [char]) {
            return "'" + [string]$value + "'"
        }

        if ($value -is [string]) {
            $escaped = ([string]$value).Replace('\', '\\').Replace('"', '\"')
            return '"' + $escaped + '"'
        }

        return [Convert]::ToString(
            $value,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $expr
    }
}

function Invoke-CppStatement {
    param(
        [Parameter(Mandatory)]
        [string]$Statement
    )

    $line = $Statement.Trim()

    if (-not $line) {
        return
    }

    if ($line -match '^#') {
        return
    }

    if ($line -match '^(int\s+)?main\s*\(') {
        return
    }

    if ($line -match '^return\b') {
        return
    }

    # const char* name = "value";
    if ($line -match '^const\s+char\s*\*\s*([A-Za-z_]\w*)\s*=\s*"(.*)";$') {
        $script:CppVars[$matches[1]] = Convert-CppStringLiteral $matches[2]
        return
    }

    # char* name = "value";
    if ($line -match '^char\s*\*\s*([A-Za-z_]\w*)\s*=\s*"(.*)";$') {
        $script:CppVars[$matches[1]] = Convert-CppStringLiteral $matches[2]
        return
    }

    # char name[] = "value";
    if ($line -match '^char\s+([A-Za-z_]\w*)\s*\[\s*\]\s*=\s*"(.*)";$') {
        $script:CppVars[$matches[1]] = Convert-CppStringLiteral $matches[2]
        return
    }

    # Character scalar.
    if ($line -match '^char\s+([A-Za-z_]\w*)\s*=\s*''([^''\\]|\\.)'';$') {
        $name = $matches[1]
        $charText = $matches[2]

        if ($charText.StartsWith('\')) {
            switch ($charText) {
                '\n' { $value = [char]"`n" }
                '\r' { $value = [char]"`r" }
                '\t' { $value = [char]"`t" }
                '\0' { $value = [char]0 }
                "\\'" { $value = [char]"'" }
                '\\' { $value = [char]'\' }
                default { throw "Unsupported C++ character escape: $charText" }
            }
        }
        else {
            $value = [char]$charText
        }

        $script:CppVars[$name] = $value
        return
    }

    # Numeric / bool / size_t declarations.
    if ($line -match '^(int|float|double|bool|size_t)\s+([A-Za-z_]\w*)\s*(?:=\s*(.+))?;$') {
        $type = $matches[1]
        $name = $matches[2]
        $expression = $matches[3]

        if ($expression) {
            $value = Invoke-CppExpression $expression
        }
        else {
            switch ($type) {
                'int'    { $value = 0 }
                'float'  { $value = 0.0 }
                'double' { $value = 0.0 }
                'bool'   { $value = $false }
                'size_t' { $value = [uint64]0 }
            }
        }

        switch ($type) {
            'int'    { $value = [int]$value }
            'float'  { $value = [single]$value }
            'double' { $value = [double]$value }
            'bool'   { $value = [bool]$value }
            'size_t' { $value = [uint64]$value }
        }

        $script:CppVars[$name] = $value
        return
    }

    #
    # Trace HRESULT-style member calls without executing the member function:
    #
    # hr = object->function(arg1, arg2, ...);
    #
    if (
        $line -match '^hr\s*=\s*([A-Za-z_]\w*)\s*->\s*([A-Za-z_]\w*)\s*\((.*)\)\s*;$'
    ) {
        $objectName = $matches[1]
        $functionName = $matches[2]
        $arguments = $matches[3]

        $args = @(Split-CppArguments $arguments)
        $formattedArgs = @()

        foreach ($arg in $args) {
            $formattedArgs += Format-CppTraceValue $arg
        }

        $argText = $formattedArgs -join ', '

        [Console]::WriteLine(
            "hr = $objectName->$functionName($argText);"
        )

        return
    }

    if ($line -match '^([A-Za-z_]\w*)\+\+;$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name]++
        return
    }

    if ($line -match '^([A-Za-z_]\w*)--;$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name]--
        return
    }

    if ($line -match '^([A-Za-z_]\w*)\s*\+=\s*(.+);$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name] += Invoke-CppExpression $matches[2]
        return
    }

    if ($line -match '^([A-Za-z_]\w*)\s*-=\s*(.+);$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name] -= Invoke-CppExpression $matches[2]
        return
    }

    if ($line -match '^([A-Za-z_]\w*)\s*\*=\s*(.+);$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name] *= Invoke-CppExpression $matches[2]
        return
    }

    if ($line -match '^([A-Za-z_]\w*)\s*/=\s*(.+);$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name] /= Invoke-CppExpression $matches[2]
        return
    }

    if ($line -match '^([A-Za-z_]\w*)\s*=\s*(.+);$') {
        $name = $matches[1]

        if (-not $script:CppVars.ContainsKey($name)) {
            throw "Undefined variable: $name"
        }

        $script:CppVars[$name] = Invoke-CppExpression $matches[2]
        return
    }

    if ($line -match '^std::cout\s*<<\s*(.+);$') {
        $output = $matches[1]
        $parts = $output -split '\s*<<\s*'

        foreach ($part in $parts) {
            $part = $part.Trim()

            if ($part -eq 'std::endl') {
                [Console]::WriteLine()
                continue
            }

            if ($part -match '^"(.*)"$') {
                $value = Convert-CppStringLiteral $matches[1]
                [Console]::Write($value)
            }
            else {
                $value = Invoke-CppExpression $part
                [Console]::Write([string]$value)
            }
        }

        return
    }

    throw "Unsupported C++ statement: $line"
}

function Invoke-CppSwitch {
    param(
        [Parameter(Mandatory)]
        [string[]]$Tokens,

        [Parameter(Mandatory)]
        [ref]$Index,

        [Parameter(Mandatory)]
        [string]$Expression,

        [bool]$Execute = $true
    )

    if ($Execute) {
        $switchValue = Invoke-CppExpression $Expression
    }
    else {
        $switchValue = $null
    }

    if (
        $Index.Value -ge $Tokens.Count -or
        $Tokens[$Index.Value].Trim() -ne '{'
    ) {
        throw "Expected '{' after switch statement."
    }

    $Index.Value++

    $body = @()
    $depth = 0

    while ($Index.Value -lt $Tokens.Count) {
        $token = $Tokens[$Index.Value].Trim()

        if ($token -eq '{') {
            $depth++
            $body += $token
            $Index.Value++
            continue
        }

        if ($token -eq '}') {
            if ($depth -eq 0) {
                $Index.Value++
                break
            }

            $depth--
            $body += $token
            $Index.Value++
            continue
        }

        $body += $token
        $Index.Value++
    }

    $sections = @()
    $currentSection = $null
    $depth = 0

    foreach ($token in $body) {
        $t = $token.Trim()

        if ($depth -eq 0) {
            if ($t -match '^case\s+(.+?)\s*:$') {
                $currentSection = [PSCustomObject]@{
                    Type       = 'case'
                    Expression = $matches[1]
                    Tokens     = [System.Collections.ArrayList]::new()
                }

                $sections += $currentSection
                continue
            }

            if ($t -match '^default\s*:$') {
                $currentSection = [PSCustomObject]@{
                    Type       = 'default'
                    Expression = $null
                    Tokens     = [System.Collections.ArrayList]::new()
                }

                $sections += $currentSection
                continue
            }
        }

        if ($null -ne $currentSection) {
            [void]$currentSection.Tokens.Add($t)
        }

        if ($t -eq '{') {
            $depth++
        }
        elseif ($t -eq '}') {
            $depth--
        }
    }

    if (-not $Execute) {
        return
    }

    $startSection = -1
    $defaultSection = -1

    for ($i = 0; $i -lt $sections.Count; $i++) {
        $section = $sections[$i]

        if ($section.Type -eq 'default') {
            $defaultSection = $i
            continue
        }

        $caseValue = Invoke-CppExpression $section.Expression

        if ($switchValue -eq $caseValue) {
            $startSection = $i
            break
        }
    }

    if ($startSection -eq -1) {
        $startSection = $defaultSection
    }

    if ($startSection -eq -1) {
        return
    }

    for (
        $sectionIndex = $startSection;
        $sectionIndex -lt $sections.Count;
        $sectionIndex++
    ) {
        $sectionTokens = @($sections[$sectionIndex].Tokens)
        $executeTokens = @()
        $nestedDepth = 0
        $breakFound = $false

        foreach ($token in $sectionTokens) {
            $t = $token.Trim()

            if ($nestedDepth -eq 0 -and $t -eq 'break;') {
                $breakFound = $true
                break
            }

            $executeTokens += $t

            if ($t -eq '{') {
                $nestedDepth++
            }
            elseif ($t -eq '}') {
                $nestedDepth--
            }
        }

        if ($executeTokens.Count -gt 0) {
            $caseIndex = 0

            Invoke-CppBlock `
                -Tokens $executeTokens `
                -Index ([ref]$caseIndex) `
                -Execute $true
        }

        if ($breakFound) {
            break
        }
    }
}

function Invoke-CppBlock {
    param(
        [Parameter(Mandatory)]
        [string[]]$Tokens,

        [Parameter(Mandatory)]
        [ref]$Index,

        [bool]$Execute = $true
    )

    while ($Index.Value -lt $Tokens.Count) {
        $token = $Tokens[$Index.Value].Trim()

        if ($token -eq '}') {
            $Index.Value++
            return
        }

        if ($token -eq '{') {
            $Index.Value++

            Invoke-CppBlock `
                -Tokens $Tokens `
                -Index $Index `
                -Execute $Execute

            continue
        }

        if ($token -match '^if\s*\((.*)\)$') {
            $conditionText = $matches[1]

            if ($Execute) {
                $condition = [bool](Invoke-CppExpression $conditionText)
            }
            else {
                $condition = $false
            }

            $Index.Value++

            if (
                $Index.Value -ge $Tokens.Count -or
                $Tokens[$Index.Value].Trim() -ne '{'
            ) {
                throw "Expected '{' after if statement."
            }

            $Index.Value++

            Invoke-CppBlock `
                -Tokens $Tokens `
                -Index $Index `
                -Execute ($Execute -and $condition)

            $branchTaken = $condition

            while ($Index.Value -lt $Tokens.Count) {
                $next = $Tokens[$Index.Value].Trim()

                if ($next -match '^else\s+if\s*\((.*)\)$') {
                    $elseIfExpression = $matches[1]

                    if ($Execute -and -not $branchTaken) {
                        $elseIfCondition = [bool](Invoke-CppExpression $elseIfExpression)
                    }
                    else {
                        $elseIfCondition = $false
                    }

                    $Index.Value++

                    if (
                        $Index.Value -ge $Tokens.Count -or
                        $Tokens[$Index.Value].Trim() -ne '{'
                    ) {
                        throw "Expected '{' after else if."
                    }

                    $Index.Value++

                    Invoke-CppBlock `
                        -Tokens $Tokens `
                        -Index $Index `
                        -Execute (
                            $Execute -and
                            -not $branchTaken -and
                            $elseIfCondition
                        )

                    if ($elseIfCondition) {
                        $branchTaken = $true
                    }

                    continue
                }

                if ($next -eq 'else') {
                    $Index.Value++

                    if (
                        $Index.Value -ge $Tokens.Count -or
                        $Tokens[$Index.Value].Trim() -ne '{'
                    ) {
                        throw "Expected '{' after else."
                    }

                    $Index.Value++

                    Invoke-CppBlock `
                        -Tokens $Tokens `
                        -Index $Index `
                        -Execute ($Execute -and -not $branchTaken)

                    break
                }

                break
            }

            continue
        }

        if ($token -match '^switch\s*\((.*)\)$') {
            $switchExpression = $matches[1]
            $Index.Value++

            Invoke-CppSwitch `
                -Tokens $Tokens `
                -Index $Index `
                -Expression $switchExpression `
                -Execute $Execute

            continue
        }

        if ($Execute) {
            Invoke-CppStatement $token
        }

        $Index.Value++
    }
}

function Invoke-Cpp {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(
            Mandatory,
            Position = 0,
            ParameterSetName = 'Path'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(
            Mandatory,
            ParameterSetName = 'Code'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Code
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw "C++ source file not found: $Path"
        }

        if ([System.IO.Path]::GetExtension($resolvedPath) -notin @('.cpp', '.cc', '.cxx', '.hpp', '.h')) {
            Write-Warning "Input file does not have a typical C/C++ source extension: $resolvedPath"
        }

        try {
            $Code = [System.IO.File]::ReadAllText($resolvedPath)
        }
        catch {
            throw "Could not read C++ source file '$resolvedPath': $($_.Exception.Message)"
        }
    }

    $script:CppVars = @{}

    # Strip block comments and // comments.
    $Code = [regex]::Replace(
        $Code,
        '/\*.*?\*/',
        '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $Code = $Code -replace '(?m)//.*$', ''

    # Put braces on their own lines.
    $Code = $Code -replace '\{', "`n{`n"
    $Code = $Code -replace '\}', "`n}`n"

    # Put case/default labels on their own lines.
    $Code = $Code -replace '(?m)^\s*(case\s+.+?:)\s*', ('$1' + "`n")
    $Code = $Code -replace '(?m)^\s*(default\s*:)\s*', ('$1' + "`n")

    $tokens = @(
        $Code -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
    )

    # Remove preprocessor lines before execution.
    $tokens = @(
        $tokens |
            Where-Object { $_ -notmatch '^#' }
    )

    $index = 0

    Invoke-CppBlock `
        -Tokens $tokens `
        -Index ([ref]$index) `
        -Execute $true
}

function Invoke-CppFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Invoke-Cpp -Path $Path
}

Export-ModuleMember -Function Invoke-Cpp, Invoke-CppFile
