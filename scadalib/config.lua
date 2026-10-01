-- scadalib/config.lua - progi alarmow i pojemnosci (zapisywane w settings)
--
--   cfg[grupa][klucz] = wartosc; 0 = alarm wylaczony / pojemnosc nieznana
--   energy            - % naladowania, alarm PONIZEJ          (domyslnie 20)
--   su:<id>           - % obciazenia stressometru, alarm OD   (domyslnie 90)
--   rpm:<id>          - RPM speedometru, alarm PONIZEJ        (domyslnie 0)
--   fluid:<nazwa>     - wiadra plynu, alarm PONIZEJ           (domyslnie 0)
--   cap:fluid:<nazwa> - pojemnosc zbiornikow z plynem (wiadra) (domyslnie 0)
--   item:<nazwa>      - sztuki przedmiotu, alarm PONIZEJ      (domyslnie 0)

local config = {}

local cfg = settings.get("scada.cfg")
if type(cfg) ~= "table" then cfg = {} end
config.data = cfg

function config.get(group, key, default)
  local g = cfg[group]
  local v = g and g[key]
  if v == nil then return default end
  return v
end

function config.set(group, key, value)
  cfg[group] = cfg[group] or {}
  cfg[group][key] = value
  settings.set("scada.cfg", cfg)
  settings.save()
end

-- Obserwowane (prog > 0) pozycje danego rodzaju w grupie: nazwa -> prog
function config.watched(group, prefix)
  local out = {}
  for k, v in pairs(cfg[group] or {}) do
    if k:sub(1, #prefix) == prefix and tonumber(v) and v > 0 then out[k:sub(#prefix + 1)] = v end
  end
  return out
end

return config
