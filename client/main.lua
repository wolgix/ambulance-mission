local ESX = nil

local TERMINATE_GAME_EVENT = 'blargleambulance:terminateGame'
local START_GAME_EVENT = 'blargleambulance:startGame'
local SERVER_EVENT = 'blargleambulance:finishLevel'

local playerData = {
    ped = nil,
    position = nil,
    vehicle = nil,
    isInAmbulance = false,
    isAmbulanceDriveable = false,
    isPlayerDead = false,
}

local gameData = {
    isPlaying = false,
    level = 1,
    peds = {}, -- {{model: model, coords: coords}}
    pedsInAmbulance = {}, -- {{model: model, coords: coords}}
    secondsLeft = 0,
    hospitalLocation = {x = 0, y = 0, z = 0, spawnPoints = {}},
    lastVehicleHealth = 1000,
}

Citizen.CreateThread(function()
    waitForEsxInitialization()
    waitForControlLoop()
    mainLoop()
end)

function waitForEsxInitialization()
    while ESX == nil do
        TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
        Citizen.Wait(0)
    end
end

function mainLoop()
    while true do
        local newPlayerData = gatherData()

        if gameData.isPlaying then
            if not newPlayerData.isInAmbulance then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_left_ambulance'), true)
            elseif not newPlayerData.isAmbulanceDriveable then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_destroyed_ambulance'), true)
            elseif newPlayerData.isPlayerDead then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_you_died'), true)
            elseif areAnyPatientsDead() then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_patient_died'), true)
            end

            handleAmbulanceDamageDetection()
        elseif not playerData.isInAmbulance and newPlayerData.isInAmbulance then
            ESX.ShowHelpNotification(_('start_game'))
        end

        playerData = newPlayerData

        Citizen.Wait(500)
    end
end

function areAnyPatientsDead()
    for _, patient in pairs(gameData.peds) do
        if IsPedDeadOrDying(patient.model, 1) then
            return true
        end
    end

    return false
end

function handleAmbulanceDamageDetection()
    local vehicleHealth = GetVehicleBodyHealth(playerData.vehicle)

    if #gameData.pedsInAmbulance > 0 and vehicleHealth < gameData.lastVehicleHealth then
        addTime(Config.LoseTimeForDamage(vehicleHealth - gameData.lastVehicleHealth))
    end

    gameData.lastVehicleHealth = vehicleHealth
end

function waitForControlLoop()
    Citizen.CreateThread(function()
        while true do
            if IsControlJustPressed(1, Config.ActivationKey) then
                if gameData.isPlaying then
                    TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_requested'), true)
                    Citizen.Wait(5000)
                elseif playerData.isInAmbulance then
                    TriggerEvent(START_GAME_EVENT)
                    ESX.ShowHelpNotification('Press ~INPUT_CONTEXT~ to stop mission.')
                    Citizen.Wait(5000)
                end
            end

            Citizen.Wait(5)
        end
    end)
end

function gatherData()
    local newPlayerData = {}
    newPlayerData.ped = PlayerPedId()
    newPlayerData.position = GetEntityCoords(playerData.ped)
    newPlayerData.vehicle = GetVehiclePedIsIn(playerData.ped, false)
    newPlayerData.isPlayerDead = IsPedDeadOrDying(newPlayerData.ped, true)

    newPlayerData.isInAmbulance = false
    newPlayerData.isAmbulanceDriveable = false

    if newPlayerData.vehicle ~= nil then
        newPlayerData.isInAmbulance = IsVehicleModel(newPlayerData.vehicle, GetHashKey('Ambulance'))

        if newPlayerData.isInAmbulance then
            newPlayerData.isAmbulanceDriveable = IsVehicleDriveable(newPlayerData.vehicle, true)
        end
    end

    return newPlayerData
end

AddEventHandler(TERMINATE_GAME_EVENT, function(reasonForTerminating, failed)
    if failed then
        Scaleform.ShowWasted(_('terminate_failed'), reasonForTerminating, 5)
        PlaySoundFrontend(-1, 'ScreenFlash', 'MissionFailedSounds', 1)
    else
        Scaleform.ShowPassed()
        PlaySoundFrontend(-1, 'Mission_Pass_Notify', 'DLC_HEISTS_GENERAL_FRONTEND_SOUNDS', 1)
    end

    gameData.isPlaying = false
    Markers.StopMarkers()
    Overlay.Stop()
    Blips.StopBlips()

    Peds.DeletePeds(mapPedsToModel(gameData.peds))
    Peds.DeletePeds(mapPedsToModel(gameData.pedsInAmbulance))
end)


AddEventHandler(START_GAME_EVENT, function()
    gameData.hospitalLocation = findNearestHospital(playerData.position)
    gameData.secondsLeft = Config.InitialSeconds
    gameData.level = 1
    gameData.peds = {}
    gameData.pedsInAmbulance = {}
    gameData.lastVehicleHealth = GetVehicleBodyHealth(playerData.vehicle)
    gameData.isPlaying = true
    
    Overlay.Start(ESX, gameData)
    Markers.StartMarkers(gameData.hospitalLocation)
    Blips.StartBlips(gameData.hospitalLocation)
    setupLevel()
    startGameLoop()
    startTimerThread()
end)

function findNearestHospital(playerPosition)
    local coordsOfNearest = Config.Hospitals[1]
    local distanceToNearest = getDistance(playerPosition, Config.Hospitals[1])

    for i = 2, #Config.Hospitals do
        local coords = Config.Hospitals[i]
        local distance = getDistance(playerPosition, coords)

        if distance < distanceToNearest then
            coordsOfNearest = coords
            distanceToNearest = distance
        end
    end

    return coordsOfNearest
end

function startTimerThread()
    Citizen.CreateThread(function()
        while gameData.isPlaying do
            Citizen.Wait(1000)
            gameData.secondsLeft = gameData.secondsLeft - 1

            if gameData.secondsLeft <= 0 then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_out_of_time'), true)
            end

            Overlay.Update(gameData)
        end
    end)
end

function startGameLoop()
    Citizen.CreateThread(function()
        while gameData.isPlaying do

            if getDistance(playerData.position, gameData.hospitalLocation) <= 10.0 and #gameData.pedsInAmbulance > 0 then
                handlePatientDropOff()
            else
                handlePatientPickUps()
            end

            Citizen.Wait(500)
        end
    end)
end

function handlePatientDropOff()
    displayMessageAndWaitUntilStopped('stop_ambulance_dropoff')

    local numberDroppedOff = #gameData.pedsInAmbulance
    Peds.DeletePeds(mapPedsToModel(gameData.pedsInAmbulance))
    gameData.pedsInAmbulance = {}
    gameData.secondsLeft = Config.InitialSeconds
    updateMarkersAndBlips()

    if #gameData.peds == 0 then
        TriggerServerEvent(SERVER_EVENT, gameData.level)

        if gameData.level == Config.MaxLevels then
            TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_finished'), false)
        else
            gameData.level = gameData.level + 1
            setupLevel()
        end
    end
end

function mapPedsToModel(peds)
    return Map.map(peds, function(ped)
        return ped.model
    end)
end

function handlePatientPickUps()
    for index, ped in pairs(gameData.peds) do
        if getDistance(playerData.position, ped.coords) <= 10.0 then
            displayMessageAndWaitUntilStopped('stop_ambulance_pickup')
            handleLoading(ped, index)
            addTime(Config.AdditionalTimeForPickup(getDistance(gameData.hospitalPosition, ped.coords)))
            updateMarkersAndBlips()
            Overlay.Update(gameData)

            if #gameData.pedsInAmbulance >= Config.MaxPatientsPerTrip then
                Scaleform.ShowMessage(_('return_to_hospital_header'), _('return_to_hospital_sub_full'), 5)
            elseif #gameData.peds == 0 then
                Scaleform.ShowMessage(_('return_to_hospital_header'), _('return_to_hospital_sub_end_level'), 5)
            end

            return
        end
    end
end

function addTime(timeToAdd)
    gameData.secondsLeft = gameData.secondsLeft + timeToAdd

    if timeToAdd > 0 then
        Scaleform.ShowAddTime(_('time_added', timeToAdd))
        PlaySoundFrontend(-1, 'Hack_Success', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true)
    elseif timeToAdd < 0 then
        Scaleform.ShowRemoveTime(_('time_removed', timeToAdd))
        PlaySoundFrontend(-1, 'Hack_Failed', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true)
    end
end

function handleLoading(ped, index)
    local freeSeat = findFirstFreeSeat()
    Peds.EnterVehicle(ped.model, playerData.vehicle, freeSeat)
    table.insert(gameData.pedsInAmbulance, ped)
    waitUntilPatientOnBus(ped)
    table.remove(gameData.peds, index)
end

function waitUntilPatientOnBus(ped)
    while gameData.isPlaying do
        if Peds.IsPedInVehicleOrTooFarAway(ped.model, ped.coords) then
            return
        end
        Citizen.Wait(50)
    end
end

function setupLevel()
    local locations = Map.shuffle(gameData.hospitalLocation.spawnPoints)
    locations = Map.filter(locations, function(location, index) return index <= gameData.level end)

    Map.forEach(locations, function(location)
        table.insert(gameData.peds, Peds.CreateRandomPedInArea(location))
    end)

    updateMarkersAndBlips()

    local subMessage = ''
    if gameData.level == 1 then
        subMessage = _('start_level_sub_one')
    else
        subMessage = _('start_level_sub_multi', gameData.level)
    end
    Scaleform.ShowMessage(_('start_level_header', gameData.level), subMessage, 5)
end

function getDistance(coords1, coords2)
    return GetDistanceBetweenCoords(coords1, coords2.x, coords2.y, coords2.z, true)
end

function displayMessageAndWaitUntilStopped(notificationMessage)
    while gameData.isPlaying and not IsVehicleStopped(playerData.vehicle) do
        ESX.ShowNotification(_(notificationMessage))
        Citizen.Wait(50)
    end
end

function findFirstFreeSeat()
    for i = 1, Config.MaxPatientsPerTrip do
        if IsVehicleSeatFree(playerData.vehicle, i) then
            return i
        end
    end

    return 0
end

function updateMarkersAndBlips()
    local coordsList = Map.map(gameData.peds, function(ped)
        return ped.coords
    end)

    Blips.UpdateBlips(coordsList)
    Markers.UpdateMarkers(coordsList)

    local isAnyoneInAmbulance = #gameData.pedsInAmbulance > 0
    Blips.SetFlashHospital(isAnyoneInAmbulance)
    Markers.SetShowHospital(isAnyoneInAmbulance)
end
