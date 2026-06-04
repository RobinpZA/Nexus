function Get-CommandCategories {
    <#
    .SYNOPSIS
        Categorises a list of command names into logical groups based on their PowerShell verb.
        Returns a structured object with categories and highlighted quick-start commands.
        Does NOT require the module to be imported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Commands
    )

    # Verb-to-category mapping
    $verbCategories = @{
        # Connection / Authentication
        'Connect'      = 'Connection'
        'Disconnect'   = 'Connection'
        'Login'        = 'Connection'
        'Logout'       = 'Connection'

        # Core Actions
        'Invoke'       = 'Actions'
        'Start'        = 'Actions'
        'Stop'         = 'Actions'
        'Restart'      = 'Actions'
        'Initialize'   = 'Actions'
        'Submit'       = 'Actions'
        'Send'         = 'Actions'
        'Sync'         = 'Actions'
        'Publish'      = 'Actions'
        'Deploy'       = 'Actions'

        # Data Retrieval
        'Get'          = 'Retrieval'
        'Find'         = 'Retrieval'
        'Search'       = 'Retrieval'
        'Read'         = 'Retrieval'
        'Receive'      = 'Retrieval'
        'Select'       = 'Retrieval'
        'Resolve'      = 'Retrieval'
        'Measure'      = 'Retrieval'
        'Test'         = 'Retrieval'
        'Confirm'      = 'Retrieval'

        # Configuration / Modification
        'Set'          = 'Configuration'
        'Update'       = 'Configuration'
        'Edit'         = 'Configuration'
        'Enable'       = 'Configuration'
        'Disable'      = 'Configuration'
        'Reset'        = 'Configuration'
        'Grant'        = 'Configuration'
        'Revoke'       = 'Configuration'
        'Protect'      = 'Configuration'
        'Unprotect'    = 'Configuration'
        'Lock'         = 'Configuration'
        'Unlock'       = 'Configuration'
        'Register'     = 'Configuration'
        'Unregister'   = 'Configuration'
        'Approve'      = 'Configuration'
        'Deny'         = 'Configuration'

        # Create / Delete
        'New'          = 'Lifecycle'
        'Add'          = 'Lifecycle'
        'Remove'       = 'Lifecycle'
        'Clear'        = 'Lifecycle'
        'Copy'         = 'Lifecycle'
        'Move'         = 'Lifecycle'
        'Rename'       = 'Lifecycle'

        # Reporting / Export
        'Export'       = 'Reporting'
        'Import'       = 'Reporting'
        'ConvertTo'    = 'Reporting'
        'ConvertFrom'  = 'Reporting'
        'Format'       = 'Reporting'
        'Out'          = 'Reporting'
        'Write'        = 'Reporting'
        'Save'         = 'Reporting'

        # Diagnostics
        'Debug'        = 'Diagnostics'
        'Trace'        = 'Diagnostics'
        'Repair'       = 'Diagnostics'
    }

    # Category display metadata
    $categoryMeta = @{
        'Connection'    = @{ order = 0; icon = '🔌'; label = 'Connection & Authentication'; description = 'Commands to connect to and disconnect from services' }
        'Actions'       = @{ order = 1; icon = '▶️'; label = 'Core Actions'; description = 'Primary commands to invoke, start, or trigger operations' }
        'Retrieval'     = @{ order = 2; icon = '📋'; label = 'Data Retrieval & Testing'; description = 'Commands to get, find, test, or query data' }
        'Configuration' = @{ order = 3; icon = '⚙️'; label = 'Configuration & Settings'; description = 'Commands to set, update, enable, or configure settings' }
        'Lifecycle'     = @{ order = 4; icon = '🔄'; label = 'Create, Modify & Remove'; description = 'Commands to create, add, remove, or manage resources' }
        'Reporting'     = @{ order = 5; icon = '📊'; label = 'Reporting & Export'; description = 'Commands to export, import, format, or save data' }
        'Diagnostics'   = @{ order = 6; icon = '🔍'; label = 'Diagnostics'; description = 'Commands to debug, trace, or repair' }
        'Other'         = @{ order = 7; icon = '📦'; label = 'Other Commands'; description = 'Commands that do not fit standard categories' }
    }

    $grouped = @{}
    $quickStart = @{
        connection = @()
        primary    = @()
    }

    foreach ($cmdName in $Commands) {
        # Extract verb (handle compound verbs like ConvertTo)
        $verb = $null
        $noun = $null
        if ($cmdName -match '^([A-Za-z]+)-(.+)$') {
            $verb = $Matches[1]
            $noun = $Matches[2]
        }

        $category = 'Other'
        if ($verb -and $verbCategories.ContainsKey($verb)) {
            $category = $verbCategories[$verb]
        }

        if (-not $grouped.ContainsKey($category)) {
            $grouped[$category] = @()
        }
        $grouped[$category] += @{
            name = $cmdName
            verb = $verb
            noun = $noun
        }

        # Quick-start identification
        if ($verb -in @('Connect', 'Login')) {
            $quickStart.connection += $cmdName
        }
        if ($verb -in @('Invoke', 'Start', 'Initialize')) {
            $quickStart.primary += $cmdName
        }
    }

    # Build sorted output
    $categories = @()
    foreach ($catKey in $grouped.Keys | Sort-Object { $categoryMeta[$_].order }) {
        $meta = $categoryMeta[$catKey]
        if (-not $meta) { $meta = $categoryMeta['Other'] }

        $categories += @{
            key         = $catKey
            label       = $meta.label
            icon        = $meta.icon
            description = $meta.description
            order       = $meta.order
            commands    = @($grouped[$catKey] | Sort-Object { $_.name })
            count       = $grouped[$catKey].Count
        }
    }

    # Sort categories by order
    $categories = @($categories | Sort-Object { $_.order })

    return [PSCustomObject]@{
        totalCommands = $Commands.Count
        categories    = $categories
        quickStart    = $quickStart
    }
}
