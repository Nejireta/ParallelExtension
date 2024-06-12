class ParallelExtension {
    [object[]]$InputObject
    [object[]]$ArgumentList
    [scriptblock]$ScriptBlock
    hidden [System.Management.Automation.Runspaces.RunspacePool]$_runspacePool
    hidden [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]$_result
    hidden [System.Collections.Concurrent.ConcurrentBag[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]]$_jobs
    hidden [System.Collections.Generic.Dictionary[[string], [array]]]$_parameters

    ParallelExtension([object[]]$inputObject, [object[]]$argumentList) {
        # initializer for class to allow passing in arguments during creation
        $this.InputObject = $inputObject
        $this.ArgumentList = $argumentList
    }

    ParallelExtension([object[]]$inputObject, [object[]]$argumentList, [scriptblock]$scriptBlock) {
        # initializer for class to allow passing in arguments during creation
        $this.InputObject = $inputObject
        $this.ArgumentList = $argumentList
        $this.ScriptBlock = $scriptBlock
    }

    [System.Collections.Generic.List[PSCustomObject]] InvokeParallel() {
        # executes a script in a parallel fashion
        try {
            $this.Init()

            foreach ($item in $this.InputObject) {
                $this.SetParameters($item)

                if ([string]::IsNullOrEmpty($this.ScriptBlock)) {
                    throw [System.ArgumentNullException]::new('Scriptblock')
                }

                $powerShell = $this.CreatePowershellInstance()
                [void]$this._jobs.Add($this.InvokePowerShell($powerShell))
            }

            return $this.WaitForJobs()
        }
        catch {
            throw
        }
    }

    [System.Collections.Generic.List[PSCustomObject]] InvokeParallel([scriptblock]$scriptBlock) {
        # executes a script in a parallel fashion
        try {
            $this.Init()

            foreach ($item in $this.InputObject) {
                $this.SetParameters($item)
                $powerShell = $this.CreatePowershellInstance([scriptblock]$scriptBlock)
                [void]$this._jobs.Add($this.InvokePowerShell($powerShell))
            }

            return $this.WaitForJobs()
        }
        catch {
            throw
        }
    }

    hidden [void] SetParameters([string]$item) {
        $pipelineArray = @()
        $pipelineArray += ($item)

        foreach ($property in $this.ArgumentList) {
            $pipelineArray += $property
        }

        # defines values in $_parameters parameter which stores the passed through variables to the PowerShell script
        #$this._parameters.Pipeline = @($item, $this.Argument)
        $this._parameters.Pipeline = $pipelineArray
    }

    hidden [System.Collections.ObjectModel.Collection[psobject]] GetIterationParameter() {
        # this can be used to dynamically find the 'InputObject' property of this class based on some criteria.
        # Checks if property have no CustomAttributes (hidden attribute) and is of type Array
        return $this.GetType().GetProperties().Where({ !$_.CustomAttributes -and $_.PropertyType.IsArray -eq $true })
    }

    hidden [System.Collections.ObjectModel.Collection[psobject]] GetParameters() {
        # this can be used to dynamically populate the _parameters property with public properties of class
        # Checks if property have no CustomAttributes (hidden attribute) and is not of type Array
        return $this.GetType().GetProperties().Where({ !$_.CustomAttributes -and $_.PropertyType.IsArray -ne $true })
    }

    hidden [PowerShell] CreatePowershellInstance() {
        # creates a new instance of PowerShell class with predefined parameters
        $powerShell = [PowerShell]::Create()
        $powerShell.RunspacePool = $this._runspacePool
        [void]$powerShell.AddScript($this.ScriptBlock, $true)
        [void]$powerShell.AddParameters($this._parameters)
        return $powerShell
    }

    hidden [PowerShell] CreatePowershellInstance([scriptblock]$scriptBlock) {
        # creates a new instance of PowerShell class with predefined parameters
        $powerShell = [PowerShell]::Create()
        $powerShell.RunspacePool = $this._runspacePool
        [void]$powerShell.AddScript($scriptBlock, $true)
        [void]$powerShell.AddParameters($this._parameters)
        return $powerShell
    }

    hidden [System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]] InvokePowerShell([powershell]$powerShell) {
        # invokes the powershell script and saves the object to a dictionary
        $jobDictionary = [System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]::new()
        [void]$jobDictionary.TryAdd('InstanceId', $powerShell.InstanceId)
        [void]$jobDictionary.TryAdd('PowerShell', $powerShell)
        [void]$jobDictionary.TryAdd('Handle', $powerShell.BeginInvoke())
        return $jobDictionary

    }

    hidden [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]] WaitForJobs() {
        # starts a while loop and saves output from completed jobs into $_result
        # potential of getting stuck forever if the underlying runspace is in a "stuck" state
        # would be possible to call the method "StopAsync" ([void]$_.PowerShell.StopAsync($null, $_.Handle)) to prematurely close the runspace
        # only supported in PowerShell 7+
        while ($true) {
            [System.Linq.Enumerable]::Where(
                $this._jobs,
                [Func[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]], bool]] {
                    param($job) $job.Handle.IsCompleted -eq $true
                }).ForEach({
                    # Adding the output from scriptblock into $ResultList
                    [void]$this._result.Add($_.PowerShell.EndInvoke($_.Handle))
                    $_.PowerShell.Dispose()
                    # Clear the dictionary entry.
                    # A better way would be to completely remove it from the list, but ConcurrentBag...
                    [void]$_.Clear()
                })

            if ($this._jobs.Keys.Count -eq 0) {
                # Breaks out of the loop to start cleanup
                break
            }
        }
        return $this._result
    }

    hidden [void] InitializeRunspacePool() {
        # creates a new RunspacePool with defines properties
        $this._runspacePool = [RunspaceFactory]::CreateRunspacePool(
            [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        )
        [void]$this._runspacePool.SetMinRunspaces(1)
        [void]$this._runspacePool.SetMaxRunspaces([System.Environment]::ProcessorCount)
        $this._runspacePool.CleanupInterval = [timespan]::FromSeconds(60)
        # The Thread will create and enter a multithreaded apartment.
        # DCOM communication requires STA ApartmentState!
        $this._runspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
        # UseNewThread for local Runspace, ReuseThread for local RunspacePool, server settings for remote Runspace and RunspacePool
        $this._runspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $this._runspacePool.Open()
    }

    hidden [void] Init() {
        # Creates/resets collection object to parameters
        $this._parameters = [System.Collections.Generic.Dictionary[[string], [array]]]::new()
        $this._jobs = [System.Collections.Concurrent.ConcurrentBag[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]]::new()
        $this._result = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

        # creates a new runspace pool
        $this.InitializeRunspacePool()
    }

    [void] Dispose() {
        # empties the collections used
        $this._parameters.Clear()
        $this._jobs.Clear()
        $this._result.Clear()

        # disposes of the RunspacePool
        if ($this._runspacePool -is [System.IDisposable]) {
            $this._runspacePool.Close()
            $this._runspacePool.Dispose()
        }

        # pokes the garbage collector to start cleanup
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
    }
}

# Example usecase of class where ping is sent to random hosts

# defines arguments to pass as parameters to class
$hashSet = [System.Collections.Generic.HashSet[ipaddress]]::new()
$inputObjectCount = 1000
$pingTimeout = 2000
for ($i = 0; $i -lt $inputObjectCount; $i++) {
    $random = [System.Random]::new()
    [void]$hashSet.Add([ipaddress]::Parse("$($random.Next(10, 240)).$($random.Next(10, 240)).$($random.Next(10, 240)).$($random.Next(10, 240))"))
}
$inputObject = [System.Linq.Enumerable]::ToArray($hashSet)
$argumentList = @($pingTimeout)

# create a ParallelExtension class and intialize it with an array to iterate through
# an additional argument as a placeholder and a scriptblock to run in parallel
# an async ping script are used for example below
$parallelExtension = [ParallelExtension]::new(
    $inputObject,
    $argumentList,
    {
        param (
            $Pipeline
        )

        $hostName = $null
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $pingResultTask = $ping.SendPingAsync($Pipeline[0], $Pipeline[1])
        $hostEntryTask = [System.Net.Dns]::GetHostEntryAsync($Pipeline[0])

        try {
            while (!$hostEntryTask.AsyncWaitHandle.WaitOne(1)) {}
            $hostName = $hostEntryTask.GetAwaiter().GetResult().HostName
        }
        catch {
            $hostName = $null
        }

        try {
            while (!$pingResultTask.AsyncWaitHandle.WaitOne(1)) {}
            $pingResult = $pingResultTask.GetAwaiter().GetResult()
            return [PSCustomObject]@{
                HostName      = $hostName
                IPAddress     = $Pipeline[0]
                Status        = $pingResult.Status
                Address       = $pingResult.Address.IPAddressToString
                RoundtripTime = ([string]::Concat($pingResult.RoundtripTime, 'ms' ))
            }
        }
        catch {
            return [PSCustomObject]@{
                HostName      = $hostName
                IPAddress     = $Pipeline[0]
                Status        = $pingResult.Status
                Address       = $pingResult.Address.IPAddressToString
                RoundtripTime = ([string]::Concat($pingResult.RoundtripTime, 'ms' ))
            }
        }
        finally {
            $ping.Dispose()
        }
    }
)


$pingResult = $parallelExtension.InvokeParallel()
# Get item where ping is successful and DNS record exists
$pingResult.Where({$_.Status -eq 'Success' -and $null -ne $_.HostName})
# Dispose of the class when it's usecase is over to flag it for the garbage collector
#$parallelExtension.Dispose()


