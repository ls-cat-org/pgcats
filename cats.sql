begin;
DROP SCHEMA cats cascade;
CREATE SCHEMA cats;
GRANT USAGE ON SCHEMA cats TO PUBLIC;

--
-- Status
--
CREATE TABLE cats.states (
       csKey serial primary key,
       csTSStart timestamp with time zone default now(),
       csTSLast  timestamp with time zone default now(),
       csStn bigint references px.stations (stnkey),

       csPower boolean,
       csAutoMode boolean,
       csDefaultStatus boolean,
       csToolNumber text,
       csPathName text,
       csLidNumberOnTool integer,
       csSampleNumberOnTool integer,
       csLidNumberMounted integer,
       csSampleNumberMounted integer,
       csPlateNumber integer,
       csWellNumber integer,
       csBarcode text,
       csPathRunning boolean,
       csLN2Reg boolean,
       csLN2Warming boolean
);
ALTER TABLE cats.states OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.statesInsertTF() returns trigger as $$
  DECLARE
    t RECORD;
  BEGIN
    SELECT * INTO t FROM cats.states WHERE csStn=px.getStation() ORDER BY csTSLast DESC LIMIT 1;
    IF FOUND THEN
      IF
        t.csPower = NEW.csPower AND
        t.csAutoMode = NEW.csAutoMode AND
        t.csDefaultStatus = NEW.csDefaultStatus AND
        t.csToolNumber = NEW.csToolNumber AND
        t.csPathName = NEW.csPathName AND
        t.csLidNumberOnTool = NEW.csLidNumberOnTool AND
        t.csSampleNumberOnTool = NEW.csSampleNumberOnTool AND
        t.csLidNumberMounted = NEW.csLidNumberMounted AND
        t.csSampleNumberMounted = NEW.csSampleNumberMounted AND
        t.csPlateNumber = NEW.csPlateNumber AND
        t.csWellNumber = NEW.csWellNumber AND
        t.csBarcode = NEW.csBarcode AND
        t.csPathRunning = NEW.csPathRunning AND
        t.csLN2Reg = NEW.csLN2Reg AND
        t.csLN2Warming = NEW.csLN2Warming
      THEN
        UPDATE cats.states SET csTSLast = now() WHERE csKey = t.csKey;
        RETURN NULL;
      END IF;
    END IF;
    RETURN NEW;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.statesInsertTF() OWNER TO lsadmin;

CREATE TRIGGER statesInsertTrigger BEFORE INSERT ON cats.states FOR EACH ROW EXECUTE PROCEDURE cats.statesInsertTF();


CREATE OR REPLACE FUNCTION cats.setstate (
       power boolean,			--  0
       autoMode boolean,		--  1
       defaultStatus boolean,		--  2
       toolNumber text,			--  3
       pathName text,			--  4
       lidNumberOnTool integer,		--  5
       sampleNumberOnTool integer,	--  6
       lidNumberMounted integer,	--  7
       sampleNumberMounted integer,	--  8
       plateNumber integer,		--  9
       wellNumber integer,		-- 10
       barcode text,			-- 11
       pathRunning boolean,		-- 12
       LN2Reg boolean,			-- 13
       LN2Warming boolean		-- 14
) returns int as $$
DECLARE
BEGIN
  INSERT INTO cats.states ( csStn, csPower, csAutoMode, csDefaultStatus, csToolNumber, csPathName,
              csLidNumberOnTool, csSampleNumberOnTool, csLidNumberMounted, csSampleNumberMounted, csPlateNumber,
              csWellNumber, csBarcode, csPathRunning, csLN2Reg, csLN2Warming)
       VALUES (  px.getStation(), power, autoMode, defaultStatus, toolNumber,  pathName,
                 lidNumberOnTool, sampleNumberOnTool, lidNumberMounted, sampleNumberMounted, plateNumber,
                 wellNumber, barcode, pathRunning, LN2Reg, LN2Warming);


  IF FOUND then
      PERFORM px.setMountedSample( toolNumber, lidNumberMounted, sampleNumberMounted);
      PERFORM px.setTooledSample( toolNumber, lidNumberOnTool, sampleNumberOnTool);
    return 1;
  ELSE
    return 0;
  END IF;
  return 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

ALTER FUNCTION cats.setstate (
       power boolean,			--  0
       autoMode boolean,		--  1
       defaultStatus boolean,		--  2
       toolNumber text,			--  3
       pathName text,			--  4
       lidNumberOnTool integer,		--  5
       sampleNumberOnTool integer,	--  6
       lidNumberMounted integer,	--  7
       sampleNumberMounted integer,	--  8
       plateNumber integer,		--  9
       wellNumber integer,		-- 10
       barcode text,			-- 11
       pathRunning boolean,		-- 12
       LN2Reg boolean,			-- 13
       LN2Warming boolean		-- 14
) OWNER TO lsadmin;



CREATE OR REPLACE FUNCTION cats.setState() returns void as $$
  DECLARE
    k bigint;
  BEGIN
    SELECT csKey INTO k FROM cats.states WHERE csStn = px.getStation() ORDER BY csTSLast DESC LIMIT 1;
    IF FOUND THEN
      UPDATE cats.states SET csTSLast = now() WHERE csKey = k;
    END IF;
    return;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.setState() OWNER TO lsadmin;


CREATE OR REPLACE FUNCTION px.setMountedSample( tool text, lid int, sampleno int) RETURNS int AS $$
  DECLARE
    cstn int;
    cdwr int;
    ccyl int;
    csmp int;
    sampId int;
    toolId int;
    diffId int;
    
  BEGIN
    cstn := px.getStation();
    toolId = (cstn<<24) | (1<<16);
    diffId = (cstn<<24) | (2<<16);
    sampId = 0;

    IF lid::int > 0 and sampleno::int > 0 THEN
    -- compute our position ID from the lid and sample number returned
    -- For sample mounted
      cdwr := lid + 2;
      SELECT ((sampleno-1)/ctnsamps)::int + ctoff, (sampleno-1)%ctnsamps+1 INTO ccyl,csmp FROM cats._cylinder2tool WHERE ctToolName=tool or ctToolNo=tool LIMIT 1;
      sampId = (cstn<<24) | (cdwr<<16) | (ccyl<<8) | (csmp);
      
      UPDATE px.holderPositions set hpTempLoc = 0 WHERE hpTempLoc = diffId;
      UPDATE px.holderPositions set hpTempLoc = diffId WHERE hpId = sampId;
    ELSE
      UPDATE px.holderPositions set hpTempLoc = 0 WHERE hpTempLoc = diffId;
    END IF;
    return sampId;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION px.setMountedSample( text, int, int) OWNER TO lsadmin;


CREATE OR REPLACE FUNCTION px.setTooledSample( tool text, lid int, sampleno int) RETURNS int AS $$
  DECLARE
    cstn int;
    cdwr int;
    ccyl int;
    csmp int;
    sampId int;
    toolId int;
    diffId int;
    
  BEGIN
    cstn := px.getStation();
    toolId = (cstn<<24) | (1<<16);
    diffId = (cstn<<24) | (2<<16);
    sampId = 0;

    IF lid::int > 0 and sampleno::int > 0 THEN
    -- computer our position ID from the lid and sample number returned
    -- For sample mounted
      cdwr := lid + 2;
      SELECT ((sampleno-1)/ctnsamps)::int + ctoff, (sampleno-1)%ctnsamps+1 INTO ccyl,csmp FROM cats._cylinder2tool WHERE ctToolName=tool or ctToolNo=tool LIMIT 1;
      sampId = (cstn<<24) | (cdwr<<16) | (ccyl<<8) | (csmp);
      
      UPDATE px.holderPositions set hpTempLoc = 0 WHERE hpTempLoc = toolId;
      UPDATE px.holderPositions set hpTempLoc = toolId WHERE hpId = sampId;
    ELSE
      UPDATE px.holderPositions set hpTempLoc = 0 WHERE hpTempLoc = toolId;
    END IF;
    return sampId;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION px.setTooledSample( text, int, int) OWNER TO lsadmin;

CREATE TABLE cats.do (
       doKey serial primary key,
       doTSStart    timestamp with time zone default now(),
       doTSLast     timestamp with time zone default now(),
       doStn bigint references px.stations (stnKey),
       doo bit(55)
);
ALTER TABLE cats.do OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.doInsertTF() returns trigger AS $$
  DECLARE
    prev record;
  BEGIN
    SELECT * INTO prev FROM cats.do WHERE dostn=px.getStation() ORDER BY doKey DESC LIMIT 1;
    IF FOUND AND prev.doo=NEW.doo THEN
      UPDATE cats.do SET doTSLast=now() WHERE doKey=prev.doKey;
      RETURN NULL;
    END IF;
    return NEW;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.doInsertTF() OWNER TO lsadmin;
CREATE TRIGGER doInsertTrigger BEFORE INSERT ON cats.do FOR EACH ROW EXECUTE PROCEDURE cats.doInsertTF();

CREATE OR REPLACE FUNCTION cats.setdo( theDo bit(99)) RETURNS VOID AS $$
  INSERT INTO cats.do (doStn, doo) VALUES (px.getStation(), $1);
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.setdo( bit(99)) OWNER TO lsadmin;

CREATE TABLE cats.di (
       diKey serial primary key,
       diTSStart    timestamp with time zone default now(),
       diTSLast     timestamp with time zone default now(),
       diStn bigint references px.stations (stnKey),
       dii bit(99)
);
ALTER TABLE cats.di OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.diInsertTF() returns trigger AS $$
  DECLARE
    prev record;
  BEGIN
    SELECT * INTO prev FROM cats.di WHERE distn=px.getStation() ORDER BY diKey DESC LIMIT 1;
    IF FOUND AND prev.dii=NEW.dii THEN
      UPDATE cats.di SET diTSLast=now() WHERE diKey=prev.diKey;
      RETURN NULL;
    END IF;
    return NEW;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.diInsertTF() OWNER TO lsadmin;
CREATE TRIGGER diInsertTrigger BEFORE INSERT ON cats.di FOR EACH ROW EXECUTE PROCEDURE cats.diInsertTF();

CREATE OR REPLACE FUNCTION cats.setdi( theDi bit(99)) RETURNS VOID AS $$
  INSERT INTO cats.di (diStn, dii) VALUES (px.getStation(), $1);
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.setdi( bit(99)) OWNER TO lsadmin;

CREATE TABLE cats.io (
       ioKey serial primary key,
       ioTSStart timestamp with time zone default now(),
       ioTSLast  timestamp with time zone default now(),
       ioStn bigint references px.stations (stnkey),

       ioCryoOK boolean,	-- 00 Cryogen Sensors OK:  1 = OK
       ioESAP   boolean,	-- 01 Emergency Stop and Air Pressure OK: 1 = OK
       ioCollisionOK boolean,	-- 02 Collision Sensor OK: 1 = No Collision
       ioCryoHighAlarm boolean, -- 03 Cryogen High Level Alarm: 1 = No Alarm
       ioCryoHigh boolean,	-- 04 Cryogen High Level: 1 = high level reached
       ioCryoLow  boolean,	-- 05 Cryogen Low Level: 1 = low level reached
       ioCryoLowAlarm boolean,	-- 06 Cryogen Low Level Alarm: 1 = no alarm
       ioCryoLiquid boolean,	-- 07 Cryogen Liquid Detection: 0=Gas, 1=Liquid
       ioInput1 boolean,	-- 08
       ioInput2 boolean,	-- 09
       ioInput3 boolean,	-- 10
       ioInput4 boolean,	-- 11
       ioCassette1 boolean,	-- 12 Cassette 1 presence:  1 = cassette in place
       ioCassette2 boolean,	-- 13 Cassette 2 presence:  1 = cassette in place
       ioCassette3 boolean,	-- 14 Cassette 3 presence:  1 = cassette in place
       ioCassette4 boolean,	-- 15 Cassette 4 presence:  1 = cassette in place
       ioCassette5 boolean,	-- 16 Cassette 5 presence:  1 = cassette in place
       ioCassette6 boolean,	-- 17 Cassette 6 presence:  1 = cassette in place
       ioCassette7 boolean,	-- 18 Cassette 7 presence:  1 = cassette in place
       ioCassette8 boolean,	-- 19 Cassette 8 presence:  1 = cassette in place
       ioCassette9 boolean,	-- 20 Cassette 9 presence:  1 = cassette in place
       ioLid1Open boolean,	-- 21 Lid 1 Opened: 1 = lid completely opened
       ioLid2Open boolean,	-- 22 Lid 2 Opened: 1 = lid completely opened
       ioLid3Open boolean,	-- 23 Lid 3 Opened: 1 = lid completely opened
       ioToolOpened boolean,	-- 24 Tool Opened: 1 = tool completely opened
       ioToolClosed boolean,	-- 25 Tool Closed: 1 = tool completely closed
       ioLimit1 boolean,	-- 26 Limit Switch 1:  0 = gripper in diffractometer position
       ioLimit2 boolean,	-- 27 Limit Switch 2:  0 = gripper in dewar position
       ioTool boolean,		-- 28 Tool Changer:	0 = tool gripped, 1 = tool released
       ioToolOC boolean,	-- 29 Tool Open/Close:  0 = tool closed, 1 = tool opened
       ioFast boolean,		-- 30 Fast Output: 0 = contact open, 1 = contact closed
       ioUnlabed1 boolean,	-- 31 Usage not documented
       ioMagnet boolean,	-- 32 Output Process Information 2 [sic], Magnet ON: 0 = contact open, 1 = contact closed
       ioOutput2 boolean,	-- 33 Output Process Information 2: 0 = contact open, 1 = contact closed
       ioOutput3 boolean,	-- 34 Output Process Information 3: 0 = contact open, 1 = contact closed
       ioOutput4 boolean,	-- 35 Output Process Information 4: 0 = contact open, 1 = contact closed
       ioGreen boolean,		-- 36 Green Light (Power, air, and Modbus network OK): 1 = OK
       ioPILZ boolean,		-- 37 PILZ Relay Reset: 1 = reset of the relay
       ioServoOn boolean,	-- 38 Servo Card ON: 1 = card on
       ioServoRot boolean,	-- 39 Servo Card Rotation +/-: 0 = toard the diffractometer, 1 = toward the dewar
       ioLN2C boolean,		-- 40 Cryogen Valve LN2_C: 0 = closed, 1 = open
       ioLN2E boolean,		-- 41 Cryogen Valve LN2_E: 0 = closed, 1 = open
       ioLG2E boolean,		-- 42 Cryogen Valve GN2_E: 0 = closed, 1 = open
       ioHeater boolean,	-- 43 Heater ON/ODD: 0 = off, 1 = on
       ioUnlabed2 boolean,	-- 44 Usage not documented
       ioUnlabed3 boolean,	-- 45 Usage not documented
       ioUnlabed4 boolean,	-- 46 Usage not documented
       ioUnlabed5 boolean	-- 47 Usage not documented
);
ALTER TABLE cats.io OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.ioInsertTF() returns trigger as $$
  DECLARE
    t record;
  BEGIN
    SELECT * INTO t FROM cats.io WHERE ioStn=px.getStation() ORDER BY ioTSLast DESC LIMIT 1;
    IF FOUND THEN
      IF
        t.ioCryoOK = NEW.ioCryoOK AND
        t.ioESAP = NEW.ioESAP AND
        t.ioCollisionOK = NEW.ioCollisionOK AND
        t.ioCryoHighAlarm = NEW.ioCryoHighAlarm AND
        t.ioCryoHigh = NEW.ioCryoHigh AND
        t.ioCryoLow  = NEW.ioCryoLow  AND
        t.ioCryoLowAlarm = NEW.ioCryoLowAlarm AND
        t.ioCryoLiquid = NEW.ioCryoLiquid AND
        t.ioInput1 = NEW.ioInput1 AND
        t.ioInput2 = NEW.ioInput2 AND
        t.ioInput3 = NEW.ioInput3 AND
        t.ioInput4 = NEW.ioInput4 AND
        t.ioCassette1 = NEW.ioCassette1 AND
        t.ioCassette2 = NEW.ioCassette2 AND
        t.ioCassette3 = NEW.ioCassette3 AND
        t.ioCassette4 = NEW.ioCassette4 AND
        t.ioCassette5 = NEW.ioCassette5 AND
        t.ioCassette6 = NEW.ioCassette6 AND
        t.ioCassette7 = NEW.ioCassette7 AND
        t.ioCassette8 = NEW.ioCassette8 AND
        t.ioCassette9 = NEW.ioCassette9 AND
        t.ioLid1Open = NEW.ioLid1Open AND
        t.ioLid2Open = NEW.ioLid2Open AND
        t.ioLid3Open = NEW.ioLid3Open AND
        t.ioToolOpened = NEW.ioToolOpened AND
        t.ioToolClosed = NEW.ioToolClosed AND
        t.ioLimit1 = NEW.ioLimit1 AND
        t.ioLimit2 = NEW.ioLimit2 AND
        t.ioTool = NEW.ioTool AND
        t.ioToolOC = NEW.ioToolOC AND
        t.ioFast = NEW.ioFast AND
        t.ioUnlabed1 = NEW.ioUnlabed1 AND
        t.ioMagnet = NEW.ioMagnet AND
        t.ioOutput2 = NEW.ioOutput2 AND
        t.ioOutput3 = NEW.ioOutput3 AND
        t.ioOutput4 = NEW.ioOutput4 AND
        t.ioGreen = NEW.ioGreen AND
        t.ioPILZ = NEW.ioPILZ AND
        t.ioServoOn = NEW.ioServoOn AND
        t.ioServoRot = NEW.ioServoRot AND
        t.ioLN2C = NEW.ioLN2C AND
        t.ioLN2E = NEW.ioLN2E AND
        t.ioLG2E = NEW.ioLG2E AND
        t.ioHeater = NEW.ioHeater AND
        t.ioUnlabed2 = NEW.ioUnlabed2 AND
        t.ioUnlabed3 = NEW.ioUnlabed3 AND
        t.ioUnlabed4 = NEW.ioUnlabed4 AND
        t.ioUnlabed5 = NEW.ioUnlabed5
      THEN
        UPDATE cats.io SET ioTSLast = now() WHERE ioKey = t.ioKey;
        RETURN NULL;
      END IF;
    END IF;
    RETURN NEW;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.ioInsertTF() OWNER TO lsadmin;

CREATE TRIGGER ioInsertTrigger BEFORE INSERT ON cats.io FOR EACH ROW EXECUTE PROCEDURE cats.ioInsertTF();


CREATE OR REPLACE FUNCTION  cats.setio(
       CryoOK boolean,	-- 00 Cryogen Sensors OK:  1 = OK
       ESAP   boolean,	-- 01 Emergency Stop and Air Pressure OK: 1 = OK
       CollisionOK boolean,	-- 02 Collision Sensor OK: 1 = No Collision
       CryoHighAlarm boolean, -- 03 Cryogen High Level Alarm: 1 = No Alarm
       CryoHigh boolean,	-- 04 Cryogen High Level: 1 = high level reached
       CryoLow  boolean,	-- 05 Cryogen Low Level: 1 = low level reached
       CryoLowAlarm boolean,	-- 06 Cryogen Low Level Alarm: 1 = no alarm
       CryoLiquid boolean,	-- 07 Cryogen Liquid Detection: 0=Gas, 1=Liquid
       Input1 boolean,	-- 08
       Input2 boolean,	-- 09
       Input3 boolean,	-- 10
       Input4 boolean,	-- 11
       Cassette1 boolean,	-- 12 Cassette 1 presence:  1 = cassette in place
       Cassette2 boolean,	-- 13 Cassette 2 presence:  1 = cassette in place
       Cassette3 boolean,	-- 14 Cassette 3 presence:  1 = cassette in place
       Cassette4 boolean,	-- 15 Cassette 4 presence:  1 = cassette in place
       Cassette5 boolean,	-- 16 Cassette 5 presence:  1 = cassette in place
       Cassette6 boolean,	-- 17 Cassette 6 presence:  1 = cassette in place
       Cassette7 boolean,	-- 18 Cassette 7 presence:  1 = cassette in place
       Cassette8 boolean,	-- 19 Cassette 8 presence:  1 = cassette in place
       Cassette9 boolean,	-- 20 Cassette 9 presence:  1 = cassette in place
       Lid1Open boolean,	-- 21 Lid 1 Opened: 1 = lid completely opened
       Lid2Open boolean,	-- 22 Lid 2 Opened: 1 = lid completely opened
       Lid3Open boolean,	-- 23 Lid 3 Opened: 1 = lid completely opened
       ToolOpened boolean,	-- 24 Tool Opened: 1 = tool completely opened
       ToolClosed boolean,	-- 25 Tool Closed: 1 = tool completely closed
       Limit1 boolean,	-- 26 Limit Switch 1:  0 = gripper in diffractometer position
       Limit2 boolean,	-- 27 Limit Switch 2:  0 = gripper in dewar position
       Tool boolean,		-- 28 Tool Changer:	0 = tool gripped, 1 = tool released
       ToolOC boolean,	-- 29 Tool Open/Close:  0 = tool closed, 1 = tool opened
       Fast boolean,		-- 30 Fast Output: 0 = contact open, 1 = contact closed
       Unlabed1 boolean,	-- 31 Usage not documented
       Magnet boolean,	-- 32 Output Process Information 2 [sic], Magnet ON: 0 = contact open, 1 = contact closed
       Output2 boolean,	-- 33 Output Process Information 2: 0 = contact open, 1 = contact closed
       Output3 boolean,	-- 34 Output Process Information 3: 0 = contact open, 1 = contact closed
       Output4 boolean,	-- 35 Output Process Information 4: 0 = contact open, 1 = contact closed
       Green boolean,		-- 36 Green Light (Power, air, and Modbus network OK): 1 = OK
       PILZ boolean,		-- 37 PILZ Relay Reset: 1 = reset of the relay
       ServoOn boolean,	-- 38 Servo Card ON: 1 = card on
       ServoRot boolean,	-- 39 Servo Card Rotation +/-: 0 = toard the diffractometer, 1 = toward the dewar
       LN2C boolean,		-- 40 Cryogen Valve LN2_C: 0 = closed, 1 = open
       LN2E boolean,		-- 41 Cryogen Valve LN2_E: 0 = closed, 1 = open
       LG2E boolean,		-- 42 Cryogen Valve GN2_E: 0 = closed, 1 = open
       Heater boolean,	-- 43 Heater ON/ODD: 0 = off, 1 = on
       Unlabed2 boolean,	-- 44 Usage not documented
       Unlabed3 boolean,	-- 45 Usage not documented
       Unlabed4 boolean,	-- 46 Usage not documented
       Unlabed5 boolean	-- 47 Usage not documented
) RETURNS INT AS $$
  BEGIN
    INSERT INTO cats.io (
       ioStn,           -- Our station
       ioCryoOK,	-- 00 Cryogen Sensors OK:  1 = OK
       ioESAP  ,	-- 01 Emergency Stop and Air Pressure OK: 1 = OK
       ioCollisionOK,	-- 02 Collision Sensor OK: 1 = No Collision
       ioCryoHighAlarm, -- 03 Cryogen High Level Alarm: 1 = No Alarm
       ioCryoHigh,	-- 04 Cryogen High Level: 1 = high level reached
       ioCryoLow ,	-- 05 Cryogen Low Level: 1 = low level reached
       ioCryoLowAlarm,	-- 06 Cryogen Low Level Alarm: 1 = no alarm
       ioCryoLiquid,	-- 07 Cryogen Liquid Detection: 0=Gas, 1=Liquid
       ioInput1,	-- 08
       ioInput2,	-- 09
       ioInput3,	-- 10
       ioInput4,	-- 11
       ioCassette1,	-- 12 Cassette 1 presence:  1 = cassette in place
       ioCassette2,	-- 13 Cassette 2 presence:  1 = cassette in place
       ioCassette3,	-- 14 Cassette 3 presence:  1 = cassette in place
       ioCassette4,	-- 15 Cassette 4 presence:  1 = cassette in place
       ioCassette5,	-- 16 Cassette 5 presence:  1 = cassette in place
       ioCassette6,	-- 17 Cassette 6 presence:  1 = cassette in place
       ioCassette7,	-- 18 Cassette 7 presence:  1 = cassette in place
       ioCassette8,	-- 19 Cassette 8 presence:  1 = cassette in place
       ioCassette9,	-- 20 Cassette 9 presence:  1 = cassette in place
       ioLid1Open,	-- 21 Lid 1 Opened: 1 = lid completely opened
       ioLid2Open,	-- 22 Lid 2 Opened: 1 = lid completely opened
       ioLid3Open,	-- 23 Lid 3 Opened: 1 = lid completely opened
       ioToolOpened,	-- 24 Tool Opened: 1 = tool completely opened
       ioToolClosed,	-- 25 Tool Closed: 1 = tool completely closed
       ioLimit1,	-- 26 Limit Switch 1:  0 = gripper in diffractometer position
       ioLimit2,	-- 27 Limit Switch 2:  0 = gripper in dewar position
       ioTool,		-- 28 Tool Changer:	0 = tool gripped, 1 = tool released
       ioToolOC,	-- 29 Tool Open/Close:  0 = tool closed, 1 = tool opened
       ioFast,		-- 30 Fast Output: 0 = contact open, 1 = contact closed
       ioUnlabed1,	-- 31 Usage not documented
       ioMagnet,	-- 32 Output Process Information 2 [sic], Magnet ON: 0 = contact open, 1 = contact closed
       ioOutput2,	-- 33 Output Process Information 2: 0 = contact open, 1 = contact closed
       ioOutput3,	-- 34 Output Process Information 3: 0 = contact open, 1 = contact closed
       ioOutput4,	-- 35 Output Process Information 4: 0 = contact open, 1 = contact closed
       ioGreen,		-- 36 Green Light (Power, air, and Modbus network OK): 1 = OK
       ioPILZ,		-- 37 PILZ Relay Reset: 1 = reset of the relay
       ioServoOn,	-- 38 Servo Card ON: 1 = card on
       ioServoRot,	-- 39 Servo Card Rotation +/-: 0 = toard the diffractometer, 1 = toward the dewar
       ioLN2C,		-- 40 Cryogen Valve LN2_C: 0 = closed, 1 = open
       ioLN2E,		-- 41 Cryogen Valve LN2_E: 0 = closed, 1 = open
       ioLG2E,		-- 42 Cryogen Valve GN2_E: 0 = closed, 1 = open
       ioHeater,	-- 43 Heater ON/ODD: 0 = off, 1 = on
       ioUnlabed2,	-- 44 Usage not documented
       ioUnlabed3,	-- 45 Usage not documented
       ioUnlabed4,	-- 46 Usage not documented
       ioUnlabed5	-- 47 Usage not documented
) VALUES (
       px.getStation(),		-- Our station
       CryoOK,	-- 00 Cryogen Sensors OK:  1 = OK
       ESAP  ,	-- 01 Emergency Stop and Air Pressure OK: 1 = OK
       CollisionOK,	-- 02 Collision Sensor OK: 1 = No Collision
       CryoHighAlarm, -- 03 Cryogen High Level Alarm: 1 = No Alarm
       CryoHigh,	-- 04 Cryogen High Level: 1 = high level reached
       CryoLow ,	-- 05 Cryogen Low Level: 1 = low level reached
       CryoLowAlarm,	-- 06 Cryogen Low Level Alarm: 1 = no alarm
       CryoLiquid,	-- 07 Cryogen Liquid Detection: 0=Gas, 1=Liquid
       Input1,	-- 08
       Input2,	-- 09
       Input3,	-- 10
       Input4,	-- 11
       Cassette1,	-- 12 Cassette 1 presence:  1 = cassette in place
       Cassette2,	-- 13 Cassette 2 presence:  1 = cassette in place
       Cassette3,	-- 14 Cassette 3 presence:  1 = cassette in place
       Cassette4,	-- 15 Cassette 4 presence:  1 = cassette in place
       Cassette5,	-- 16 Cassette 5 presence:  1 = cassette in place
       Cassette6,	-- 17 Cassette 6 presence:  1 = cassette in place
       Cassette7,	-- 18 Cassette 7 presence:  1 = cassette in place
       Cassette8,	-- 19 Cassette 8 presence:  1 = cassette in place
       Cassette9,	-- 20 Cassette 9 presence:  1 = cassette in place
       Lid1Open,	-- 21 Lid 1 Opened: 1 = lid completely opened
       Lid2Open,	-- 22 Lid 2 Opened: 1 = lid completely opened
       Lid3Open,	-- 23 Lid 3 Opened: 1 = lid completely opened
       ToolOpened,	-- 24 Tool Opened: 1 = tool completely opened
       ToolClosed,	-- 25 Tool Closed: 1 = tool completely closed
       Limit1,	-- 26 Limit Switch 1:  0 = gripper in diffractometer position
       Limit2,	-- 27 Limit Switch 2:  0 = gripper in dewar position
       Tool,		-- 28 Tool Changer:	0 = tool gripped, 1 = tool released
       ToolOC,	-- 29 Tool Open/Close:  0 = tool closed, 1 = tool opened
       Fast,		-- 30 Fast Output: 0 = contact open, 1 = contact closed
       Unlabed1,	-- 31 Usage not documented
       Magnet,	-- 32 Output Process Information 2 [sic], Magnet ON: 0 = contact open, 1 = contact closed
       Output2,	-- 33 Output Process Information 2: 0 = contact open, 1 = contact closed
       Output3,	-- 34 Output Process Information 3: 0 = contact open, 1 = contact closed
       Output4,	-- 35 Output Process Information 4: 0 = contact open, 1 = contact closed
       Green,		-- 36 Green Light (Power, air, and Modbus network OK): 1 = OK
       PILZ,		-- 37 PILZ Relay Reset: 1 = reset of the relay
       ServoOn,	-- 38 Servo Card ON: 1 = card on
       ServoRot,	-- 39 Servo Card Rotation +/-: 0 = toard the diffractometer, 1 = toward the dewar
       LN2C,		-- 40 Cryogen Valve LN2_C: 0 = closed, 1 = open
       LN2E,		-- 41 Cryogen Valve LN2_E: 0 = closed, 1 = open
       LG2E,		-- 42 Cryogen Valve GN2_E: 0 = closed, 1 = open
       Heater,	-- 43 Heater ON/ODD: 0 = off, 1 = on
       Unlabed2,	-- 44 Usage not documented
       Unlabed3,	-- 45 Usage not documented
       Unlabed4,	-- 46 Usage not documented
       Unlabed5	-- 47 Usage not documented
);

  RETURN 1;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.setio( 
       CryoOK boolean,	-- 00 Cryogen Sensors OK:  1 = OK
       ESAP   boolean,	-- 01 Emergency Stop and Air Pressure OK: 1 = OK
       CollisionOK boolean,	-- 02 Collision Sensor OK: 1 = No Collision
       CryoHighAlarm boolean, -- 03 Cryogen High Level Alarm: 1 = No Alarm
       CryoHigh boolean,	-- 04 Cryogen High Level: 1 = high level reached
       CryoLow  boolean,	-- 05 Cryogen Low Level: 1 = low level reached
       CryoLowAlarm boolean,	-- 06 Cryogen Low Level Alarm: 1 = no alarm
       CryoLiquid boolean,	-- 07 Cryogen Liquid Detection: 0=Gas, 1=Liquid
       Input1 boolean,	-- 08
       Input2 boolean,	-- 09
       Input3 boolean,	-- 10
       Input4 boolean,	-- 11
       Cassette1 boolean,	-- 12 Cassette 1 presence:  1 = cassette in place
       Cassette2 boolean,	-- 13 Cassette 2 presence:  1 = cassette in place
       Cassette3 boolean,	-- 14 Cassette 3 presence:  1 = cassette in place
       Cassette4 boolean,	-- 15 Cassette 4 presence:  1 = cassette in place
       Cassette5 boolean,	-- 16 Cassette 5 presence:  1 = cassette in place
       Cassette6 boolean,	-- 17 Cassette 6 presence:  1 = cassette in place
       Cassette7 boolean,	-- 18 Cassette 7 presence:  1 = cassette in place
       Cassette8 boolean,	-- 19 Cassette 8 presence:  1 = cassette in place
       Cassette9 boolean,	-- 20 Cassette 9 presence:  1 = cassette in place
       Lid1Open boolean,	-- 21 Lid 1 Opened: 1 = lid completely opened
       Lid2Open boolean,	-- 22 Lid 2 Opened: 1 = lid completely opened
       Lid3Open boolean,	-- 23 Lid 3 Opened: 1 = lid completely opened
       ToolOpened boolean,	-- 24 Tool Opened: 1 = tool completely opened
       ToolClosed boolean,	-- 25 Tool Closed: 1 = tool completely closed
       Limit1 boolean,	-- 26 Limit Switch 1:  0 = gripper in diffractometer position
       Limit2 boolean,	-- 27 Limit Switch 2:  0 = gripper in dewar position
       Tool boolean,		-- 28 Tool Changer:	0 = tool gripped, 1 = tool released
       ToolOC boolean,	-- 29 Tool Open/Close:  0 = tool closed, 1 = tool opened
       Fast boolean,		-- 30 Fast Output: 0 = contact open, 1 = contact closed
       Unlabed1 boolean,	-- 31 Usage not documented
       Magnet boolean,	-- 32 Output Process Information 2 [sic], Magnet ON: 0 = contact open, 1 = contact closed
       Output2 boolean,	-- 33 Output Process Information 2: 0 = contact open, 1 = contact closed
       Output3 boolean,	-- 34 Output Process Information 3: 0 = contact open, 1 = contact closed
       Output4 boolean,	-- 35 Output Process Information 4: 0 = contact open, 1 = contact closed
       Green boolean,		-- 36 Green Light (Power, air, and Modbus network OK): 1 = OK
       PILZ boolean,		-- 37 PILZ Relay Reset: 1 = reset of the relay
       ServoOn boolean,	-- 38 Servo Card ON: 1 = card on
       ServoRot boolean,	-- 39 Servo Card Rotation +/-: 0 = toard the diffractometer, 1 = toward the dewar
       LN2C boolean,		-- 40 Cryogen Valve LN2_C: 0 = closed, 1 = open
       LN2E boolean,		-- 41 Cryogen Valve LN2_E: 0 = closed, 1 = open
       LG2E boolean,		-- 42 Cryogen Valve GN2_E: 0 = closed, 1 = open
       Heater boolean,	-- 43 Heater ON/ODD: 0 = off, 1 = on
       Unlabed2 boolean,	-- 44 Usage not documented
       Unlabed3 boolean,	-- 45 Usage not documented
       Unlabed4 boolean,	-- 46 Usage not documented
       Unlabed5 boolean	-- 47 Usage not documented
) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.setIO() returns void as $$
  DECLARE
    k bigint;
  BEGIN
    SELECT ioKey INTO k FROM cats.io WHERE ioStn=px.getStation() ORDER BY ioTSLast DESC LIMIT 1;
    IF FOUND THEN
      UPDATE cats.io SET ioTSLast = now() WHERE ioKey=k;
    END IF;
    return;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.setIO() OWNER TO lsadmin;


CREATE TABLE cats.positions (
       pKey serial primary key,
       pTSStart timestamp with time zone default now(),
       pTSLast  timestamp with time zone default now(),
       pStn bigint references px.stations (stnkey),

       pX numeric(20,6),
       pY numeric(20,6),
       pZ numeric(20,6),
       pRX numeric(20,6),
       pRY numeric(20,6),
       pRZ numeric(20,6)
);
ALTER TABLE cats.positions OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.positionsInsertTF() returns trigger as $$
  DECLARE
    t record;
  BEGIN
    SELECT * INTO t FROM cats.positions WHERE pStn=px.getStation() ORDER BY pTSLast DESC LIMIT 1;
    IF FOUND THEN
      IF
        t.pX = NEW.pX AND
        t.pY = NEW.pY AND
        t.pZ = NEW.pZ AND
        t.pRX = NEW.pRX AND
        t.pRY = NEW.pRY AND
        t.pRZ = NEW.pRZ
      THEN
        UPDATE cats.positions SET pTSLast = now() WHERE pKey = t.pKey;
        RETURN NULL;
      END IF;
    END IF;
    RETURN NEW;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.positionsInsertTF() OWNER TO lsadmin;

CREATE TRIGGER positionsInsertTrigger BEFORE INSERT ON cats.positions FOR EACH ROW EXECUTE PROCEDURE cats.positionsInsertTF();

CREATE OR REPLACE FUNCTION cats.setposition( x numeric(20,6), y numeric(20,6), z numeric(20,6), rx numeric(20,6), ry numeric(20,6), rz numeric(20,6)) returns int as $$
  BEGIN
    INSERT INTO cats.positions ( pStn, pX, pY, pZ, pRX, pRY, pRZ) VALUES ( px.getStation(), x, y, z, rx, ry, rz);
    RETURN 1;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.setposition( numeric(20,6), numeric(20,6), numeric(20,6), numeric(20,6), numeric(20,6), numeric(20,6)) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.setPosition() returns void as $$
  DECLARE
    k bigint;
  BEGIN
    SELECT pKey INTO k FROM cats.positions WHERE pStn = px.getStation() ORDER BY pTSLast LIMIT 1;
    IF FOUND THEN
      UPDATE cats.positions SET pTSLast = now() WHERE pKey = k;
    END IF;
    RETURN;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.setPosition() OWNER TO lsadmin;

CREATE TABLE cats.messages (
       mKey serial primary key,
       mTSStart timestamp with time zone default now(),
       mTSLast timestamp with time zone default now(),
       mStn bigint references px.stations (stnkey),
       mmsg text
);
ALTER TABLE cats.messages OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.messagesInsertTF() returns trigger as $$
  DECLARE
    t record;
  BEGIN
    SELECT * INTO t FROM cats.messages WHERE mStn=px.getStation() ORDER BY mTSLast DESC LIMIT 1;
    IF FOUND THEN
      IF t.mmsg = NEW.mmsg THEN
        UPDATE cats.messages SET mTSLast = now() WHERE mKey = t.mKey;
        RETURN NULL;
      END IF;
    END IF;
    RETURN NEW;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.messagesInsertTF() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.setmessage( msg text) returns int as $$
  BEGIN
    INSERT INTO cats.messages (mStn, mmsg) VALUES (px.getStation(), msg);
    RETURN 1;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.setmessage( text) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.setMessage() returns void as $$
  DECLARE
    k bigint;
  BEGIN
    SELECT mKey INTO k FROM cats.messages WHERE mStn=px.getStation() ORDER BY mTSLast DESC LIMIT 1;
    IF FOUND THEN
      UPDATE cats.messages SET mTSLast = now() WHERE mKey = k;
    END IF;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

ALTER FUNCTION cats.setMessage() OWNER TO lsadmin;


CREATE TABLE cats._queue (
       qKey serial primary key,		-- our key
       qts timestamp with time zone not null default now(),
       qaddr inet not null,		-- IP address of catsOK routine
       qCmd text not null		-- the command
);
ALTER TABLE cats._queue OWNER TO lsadmin;
       


CREATE OR REPLACE FUNCTION cats._pushqueue( cmd text) RETURNS VOID AS $$
  DECLARE
    c text;	    -- trimmed command
    ntfy text;	    -- used to generate notify command
    theRobot inet;  -- address of CatsOk routine
  BEGIN
    SELECT cnotifyrobot, crobot INTO ntfy, theRobot FROM px._config LEFT JOIN px.stations ON cstation=stnname WHERE stnkey=px.getstation();
    IF NOT FOUND THEN
      RETURN;
    END IF;
    c := trim( cmd);
    IF length( c) > 0 THEN
      --
      -- Delete remaining commands in the queue during an abort or panic
      IF lower(c) = 'abort' or lower(c) = 'panic'  THEN
        DELETE FROM cats._queue WHERE qaddr = theRobot;
      END IF;

      INSERT INTO cats._queue (qcmd, qaddr) VALUES (c, theRobot);
      IF FOUND THEN
        EXECUTE 'NOTIFY ' || ntfy;
      ELSE
        RAISE EXCEPTION 'Client is not associated with a robot: %', inet_client_addr();
      END IF;
    END IF;
    RETURN;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats._pushqueue( text) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats._popqueue() RETURNS TEXT AS $$
  DECLARE
    rtn text;		-- return value
    qk   bigint;	-- queue key of item
  BEGIN
    rtn := '';
    SELECT qCmd, qKey INTO rtn, qk FROM cats._queue WHERE qaddr=inet_client_addr() ORDER BY qKey ASC LIMIT 1;
    IF NOT FOUND THEN
      return '';
    END IF;
    DELETE FROM cats._queue WHERE qKey=qk;
    return rtn;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats._popqueue() OWNER TO lsadmin;


CREATE OR REPLACE FUNCTION cats.init() RETURNS VOID AS $$
  --
  -- Called by process controlling the robot
  --
  DECLARE
    ntfy text;
  BEGIN
    DELETE FROM cats._queue WHERE qaddr = inet_client_addr();    
    SELECT cnotifyrobot INTO ntfy FROM px._config WHERE cstnkey=px.getstation();
    IF FOUND THEN
       EXECUTE 'LISTEN ' || ntfy;
    END IF;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.init() OWNER TO lsadmin;


CREATE TABLE cats._acmds (
	-- CATS commands that require an argument
       ac text primary key
);
INSERT INTO cats._acmds (ac) VALUES ('backup');
INSERT INTO cats._acmds (ac) VALUES ('restore');
INSERT INTO cats._acmds (ac) VALUES ('home');
INSERT INTO cats._acmds (ac) VALUES ('safe');
INSERT INTO cats._acmds (ac) VALUES ('reference');
INSERT INTO cats._acmds (ac) VALUES ('put');
INSERT INTO cats._acmds (ac) VALUES ('put_bcrd');
INSERT INTO cats._acmds (ac) VALUES ('get');
INSERT INTO cats._acmds (ac) VALUES ('get_bcrd');
INSERT INTO cats._acmds (ac) VALUES ('getput');
INSERT INTO cats._acmds (ac) VALUES ('getput_bcrd');
INSERT INTO cats._acmds (ac) VALUES ('barcode');
INSERT INTO cats._acmds (ac) VALUES ('transfer');
INSERT INTO cats._acmds (ac) VALUES ('soak');
INSERT INTO cats._acmds (ac) VALUES ('dry');
INSERT INTO cats._acmds (ac) VALUES ('putplate');
INSERT INTO cats._acmds (ac) VALUES ('getplate');
INSERT INTO cats._acmds (ac) VALUES ('getputplate');
INSERT INTO cats._acmds (ac) VALUES ('goto_well');
INSERT INTO cats._acmds (ac) VALUES ('adjust');
INSERT INTO cats._acmds (ac) VALUES ('focus');
INSERT INTO cats._acmds (ac) VALUES ('expose');
INSERT INTO cats._acmds (ac) VALUES ('collect');
INSERT INTO cats._acmds (ac) VALUES ('setplateangle');


CREATE TABLE cats._args (
       -- Used to generate argument lists for CATS control functions
       aKey serial primary key,
       aTS timestamp with time zone default now(),
       aCmd text NOT NULL references cats._acmds (ac) on update cascade,	-- here are the legal commands       
       aCap int default 0,		-- USB port or tool number
       aLid int default 0,		-- lid number (AKA dewar nuber)
       aSample int default 0,		-- sample number within dewar
       aNewLid int default 0,		-- new lid to which to transfer sample
       aNewSample int default 0,	-- new sample position to transfer to
       aXtalPlate int default 0,	-- Crystallization plate number
       aWell int default 0,		-- number of well to go to
       aArg7 int default 0,		-- spare argument
       aArg8 int default 0,		-- spare argument
       aArg9 int default 0,		-- spare argument
       aXShift float default 0.0,	-- X offset
       aYShift float default 0.0,	-- Y offset
       aZShift float default 0.0,	-- Z offset
       aAngle float default 0.0,	-- Angle
       aOscs int default 0,		-- number of oscillations
       aExp float default 0.0,		-- exposure time
       aStep float default 0.0,		-- angular step
       aFinal float default 0.0,	-- Final Angle
       aArg18 int default 0,		-- spare argument
       aArg19 int default 0		-- spare argument
);
ALTER TABLE cats._args OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats._gencmd( k bigint) returns text as $$
  DECLARE
    rtn text;
  BEGIN
    rtn := '';
    SELECT aCmd || '(' || aCap || ',' || aLid || ',' || aSample || ',' || aNewLid || ',' || aNewSample || ',' ||
        aXtalPlate || ',' || aWell || ',' || aArg7 || ',' || aArg8 || ',' || aArg9 || ',' || 
        aXShift || ',' || aYShift || ',' || aZShift || ',' || aAngle || ',' || 
        aOscs || ',' || aExp || ',' || aStep || ',' || aFinal || ',' || aArg18 || ',' || aArg19 || ')'
      INTO rtn
      FROM cats._args
      WHERE aKey = k;
    IF FOUND THEN
      DELETE FROM cats._args WHERE aKey=k;
    END IF;
    return rtn;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats._gencmd( bigint) OWNER TO lsadmin;

CREATE TABLE cats._cylinder2tool (
       ctKey serial primary key,	-- our primary key
       ctcyl int unique,		-- our normalized cylinder number (1-255) Must be unique as we'll expect one and only one row give a cylinder number
       ctoff int,			-- offset to a zero based cylinder number (0-2)
       ctnsamps int,			-- number of sample positions in this cylinder
       cttoolno int,			-- the CATS tool number needed to access this cylinder
       cttoolname text			-- the name of the corresponding CATS tool (control requires number, status replies with name)
);
ALTER TABLE cats._cylinder2tool OWNER TO lsadmin;

INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  1,  1, 10, 1, 'SPINE');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  2,  1, 10, 1, 'SPINE');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  3,  1, 10, 1, 'SPINE');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  4,  4, 12, 3, 'Rigaku');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  5,  4, 12, 3, 'Rigaku');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  6,  4, 12, 3, 'Rigaku');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  7,  7, 16, 4, 'ALS');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  8,  7, 16, 4, 'ALS');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES (  9,  7, 16, 4, 'ALS');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES ( 10, 10, 16, 5, 'UNI');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES ( 11, 10, 16, 5, 'UNI');
INSERT INTO cats._cylinder2tool (ctcyl, ctoff, ctnsamps, cttoolno, cttoolname) VALUES ( 12, 10, 16, 5, 'UNI');

CREATE TABLE cats._toolCorrection (
       tckey serial primary key,
       tcstn bigint references px.stations (stnkey),
       tcts  timestamp with time zone default now(),
       tcTool int not null default 0,
       tcX int not null default 0,
       tcY int not null default 0,
       tcZ int not null default 0
);


CREATE OR REPLACE FUNCTION cats._mkcryocmd( theCmd text, theId int, theNewId int, xx int, yy int, zz int) RETURNS INT AS $$
  --
  -- All the cryocrystallography commands have very similar requirements
  -- This is a low level function to service the put, get, (and getput), as well as the brcd flavors
  -- Also, the barcode, transfer, soak, dry, home, safe, and reference commands are supported here
  --
  DECLARE
    rtn int;	-- return: 1 on success, 0 on failure

    ison boolean;  -- true when the robot is "on"
	--
	-- Convert theId so something the robot can use
    cstn1 int;	-- control system's station number
    cdwr1 int;	-- control system's dewar number
    ccyl1 int;	-- control system's cylinder number
    csmp1 int;	-- control system's sample number
    rlid1 int;	-- robot's lid number
    rtool1 int;	-- robot's tool number
    rsmpl1 int;	-- robot's sample number

    cstn2 int;	-- control system's station number
    cdwr2 int;	-- control system's dewar number
    ccyl2 int;	-- control system's cylinder number
    csmp2 int;	-- control system's sample number
    rlid2 int;	-- robot's lid number
    rtool2 int;	-- robot's tool number
    rsmpl2 int;	-- robot's sample number

    tc record;  -- tool correction: a kludge to finetune the diffractometer position

  BEGIN
    rtn := 0;

    SELECT cspower INTO ison FROM cats.states WHERE csstn=px.getStation() ORDER BY csKey DESC LIMIT 1;
    IF FOUND and not ison THEN
      PERFORM cats._pushqueue( 'on');
    END IF;    

    INSERT INTO cats._args (aCmd) VALUES ( theCmd);

    --
    -- theId is zero for an "get".  Here we need to get the tool number from the current state
    --
    IF theId = 0 THEN
      SELECT cttoolno INTO rtool1 FROM cats.states LEFT JOIN cats._cylinder2tool ON ctToolName=csToolNumber WHERE csstn=px.getStation() ORDER BY csKey desc LIMIT 1;
      IF FOUND THEN
        UPDATE cats._args SET aCap=rtool1 WHERE aKey=currval('cats._args_akey_seq');
      END IF;
    END IF;

    IF theId != 0 THEN
      --
      -- Pick out the control system's numbers
      -- home, safe, get, soak, and dry need at least an ID corresponding to a cylinder to choose the right tool
      --
      cstn1 := (theId & x'ff000000'::int) >> 24;
      cdwr1 := (theId & x'00ff0000'::int) >> 16;
      ccyl1 := (theId & x'0000ff00'::int) >>  8;
      csmp1 :=  theId & x'000000ff'::int;
      --
      -- Find the Robot's numbers
      --
      -- 1 = current tool, 2 = diffractometer, 3-5 = lids
      -- For now only allow references to lid positions in the CATS dewar
      IF cdwr1 < 3 or cdwr1 > 5 THEN
        return 0;
      END IF;
      rlid1 := cdwr1 - 2;

      SELECT cttoolno, (ccyl1-ctoff)*ctnsamps + csmp1 INTO rtool1, rsmpl1 FROM cats._cylinder2tool WHERE ctcyl=ccyl1;
      IF NOT FOUND THEN
        return 0;
      END IF;
      -- Now we know what we want
      UPDATE cats._args SET aCap=rtool1, aLid=rlid1, aSample=rsmpl1 WHERE akey=currval('cats._args_akey_seq');
    END IF;

    IF theId != 0 and theNewId != 0 THEN
      --
      -- Pick out the control system's numbers
      --
      cstn2 := (theNewId & x'ff000000'::int) >> 24;
      cdwr2 := (theNewId & x'00ff0000'::int) >> 16;
      ccyl2 := (theNewId & x'0000ff00'::int) >>  8;
      csmp2 :=  theNewId & x'000000ff'::int;
      --
      -- Find the Robot's numbers
      --
      -- 1 = current tool, 2 = diffractometer, 3-5 = lids
      -- For now only allow reference to position in the CATS dewar
      IF cdwr2 < 3 or cdwr2 > 5 THEN
        return 0;
      END IF;
      rlid2 := cdwr2 - 2;

      SELECT cttoolno, (ccyl2-ctoff)*ctnsamps + csmp2 INTO rtool2, rsmpl2 FROM cats._cylinder2tool WHERE ctcyl=ccyl2;
      IF NOT FOUND OR rtool1 != rtool2 THEN
        return 0;
      END IF;
      -- Now we know what we want
      UPDATE cats._args SET aNewLid=rlid2, aNewSample=rsmpl2 WHERE akey=currval('cats._args_akey_seq');
    END IF;


    SELECT * INTO tc FROM cats._toolCorrection WHERE tcstn=px.getStation() and tcTool = rtool1 ORDER BY tcKey DESC LIMIT 1;
    IF FOUND THEN
      UPDATE cats._args SET aXShift = xx + tc.tcx, aYShift = yy + tc.tcy, aZShift = zz + tc.tcz WHERE aKey=currval('cats._args_akey_seq');
    ELSE
      UPDATE cats._args SET aXShift = xx, aYShift = yy, aZShift = zz WHERE aKey=currval('cats._args_akey_seq');
    END IF;

    PERFORM cats._pushqueue( cats._gencmd( currval( 'cats._args_akey_seq')));
    return 1;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats._mkcryocmd( text, int, int, int, int, int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.put( theId int, x int, y int, z int) returns int AS $$
  SELECT cats._mkcryocmd( 'put', $1, 0, $2, $3, $4);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.put( int, int, int, int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.put_bcrd( theId int, x int, y int, z int) returns int AS $$
  SELECT cats._mkcryocmd( 'put_bcrd', $1, 0, $2, $3, $4);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.put_bcrd( int, int, int, int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.get( x int, y int, z int) returns int AS $$
  SELECT cats._mkcryocmd( 'get', 0, 0, $1, $2, $3);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.get( int, int, int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.getput( theId int, xx int, yy int, zz int) returns int AS $$
  DECLARE
    rtn int;
    tool1 int;
    tool2 int;
  BEGIN
    SELECT cttoolno INTO tool1 FROM cats._cylinder2tool WHERE ctcyl = (px.getCurrentSampleID() & x'0000ff00'::int) >> 8;
    SELECT cttoolno INTO tool2 FROM cats._cylinder2tool WHERE ctcyl = (theId                   & x'0000ff00'::int) >> 8;

    IF tool1 != tool2 THEN
      PERFORM cats.get( xx, yy, zz);
      SELECT cats.put( theId, xx, yy, zz) INTO rtn;
    ELSE
      SELECT cats._mkcryocmd( 'getput', theId, 0, xx, yy, zz) INTO rtn;
    END IF;
    return rtn;
  END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION cats.getput( int, int, int, int) OWNER TO lsadmin;




CREATE OR REPLACE FUNCTION cats.getput_bcrd( theId int, x int, y int, z int) returns int AS $$
  SELECT cats._mkcryocmd( 'getput_bcrd', $1, 0, $2, $3, $4);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.getput_bcrd( int, int, int, int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.barcode( theId int) returns int AS $$
  SELECT cats._mkcryocmd( 'barcode', $1, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.barcode( int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.transfer( theId int, theNewId int) returns int AS $$
  SELECT cats._mkcryocmd( 'transfer', $1, $2, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.transfer( int, int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.soak( theId int) returns int AS $$
  SELECT cats._mkcryocmd( 'soak', $1, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.soak( int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.dry( theId int) returns int AS $$
  SELECT cats._mkcryocmd( 'dry', $1, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.dry( int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.home( theId int) returns int AS $$
  SELECT cats._mkcryocmd( 'home', $1, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.home( int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.back( theId int) returns int AS $$
  SELECT cats._mkcryocmd( 'back', $1, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.back( int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.safe( theId int) returns int AS $$
  SELECT cats._mkcryocmd( 'safe', $1, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.safe( int) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.reference( ) returns int AS $$
  SELECT cats._mkcryocmd( 'reference', 0, 0, 0, 0, 0);
$$ LANGUAGE sql SECURITY DEFINER;
ALTER FUNCTION cats.reference( ) OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.openlid1() returns void AS $$
  SELECT cats._pushqueue( 'openlid1');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.openlid1() OWNER TO lsadmin;
  
CREATE OR REPLACE FUNCTION cats.openlid2() returns void AS $$
  SELECT cats._pushqueue( 'openlid2');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.openlid2() OWNER TO lsadmin;
  

CREATE OR REPLACE FUNCTION cats.openlid3() returns void AS $$
  SELECT cats._pushqueue( 'openlid3');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.openlid3() OWNER TO lsadmin;
  
CREATE OR REPLACE FUNCTION cats.closelid1() returns void AS $$
  SELECT cats._pushqueue( 'closelid1');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.closelid1() OWNER TO lsadmin;
  
CREATE OR REPLACE FUNCTION cats.closelid2() returns void AS $$
  SELECT cats._pushqueue( 'closelid2');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.closelid2() OWNER TO lsadmin;
  

CREATE OR REPLACE FUNCTION cats.closelid3() returns void AS $$
  SELECT cats._pushqueue( 'closelid3');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.closelid3() OWNER TO lsadmin;
  
CREATE OR REPLACE FUNCTION cats.opentool() returns void AS $$
  SELECT cats._pushqueue( 'opentool');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.opentool() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.closetool() returns void AS $$
  SELECT cats._pushqueue( 'closetool');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.closetool() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.magneton() returns void AS $$
  SELECT cats._pushqueue( 'magneton');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.magneton() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.magnetoff() returns void AS $$
  SELECT cats._pushqueue( 'magnetoff');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.magnetoff() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.heateron() returns void AS $$
  SELECT cats._pushqueue( 'heateron');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.heateron() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.heateroff() returns void AS $$
  SELECT cats._pushqueue( 'heateroff');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.heateroff() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.regulon() returns void AS $$
  SELECT cats._pushqueue( 'regulon');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.regulon() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.reguloff() returns void AS $$
  SELECT cats._pushqueue( 'reguloff');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.reguloff() OWNER TO lsadmin;


CREATE OR REPLACE FUNCTION cats.warmon() returns void AS $$
  SELECT cats._pushqueue( 'warmon');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.warmon() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.warmoff() returns void AS $$
  SELECT cats._pushqueue( 'warmoff');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.warmoff() OWNER TO lsadmin;


CREATE OR REPLACE FUNCTION cats.on() returns void AS $$
  SELECT cats._pushqueue( 'on');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.on() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.off() returns void AS $$
  SELECT cats._pushqueue( 'off');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.off() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.abort() returns void AS $$
  SELECT cats._pushqueue( 'abort');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.abort() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.reset() returns void AS $$
  SELECT cats._pushqueue( 'reset');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.reset() OWNER TO lsadmin;


CREATE OR REPLACE FUNCTION cats.panic() returns void AS $$
  SELECT cats._pushqueue( 'panic');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.panic() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.pause() returns void AS $$
  SELECT cats._pushqueue( 'pause');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.pause() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.restart() returns void AS $$
  SELECT cats._pushqueue( 'restart');
$$ LANGUAGE SQL SECURITY DEFINER;
ALTER FUNCTION cats.restart() OWNER TO lsadmin;


CREATE TABLE cats.magnetstates (
       msKey serial primary key,
       msTS timestamp with time zone default now(),
       msStn bigint references px.stations (stnkey),
       msSamplePresent boolean not null
);
ALTER TABLE cats.magnetstates OWNER to lsadmin;

CREATE OR REPLACE FUNCTION cats.recover_SPINE_dismount_failure() returns boolean AS $$
  DECLARE
    rtn boolean;
    ta  record;		-- transfer arguments
  BEGIN
    rtn := True;
    PERFORM cats.abort();
    PERFORM cats.reset();
    PERFORM cats.back(0);
    SELECT * INTO ta FROM px.transferArgs WHERE taStn=px.getstation() ORDER BY taKey DESC LIMIT 1;
    PERFORM px.startTransfer( ta.cursam, False, ta.taxx, ta.tayy, ta.tazz);
    PERFORM px.startTransfer( ta.taId, False, ta.taxx, ta.tayy, ta.tazz);

    return rtn;
  END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;
ALTER FUNCTION cats.recover_SPINE_dismount_failure() OWNER TO lsadmin;

CREATE OR REPLACE FUNCTION cats.recover_dismount_failure() returns boolean AS $$
  DECLARE
   rtn boolean;
   tn int;   -- current tool number
  BEGIN
    rtn := FALSE;
    SELECT cttoolno INTO tn FROM cats._cylinder2tool LEFT JOIN cats.states ON csToolNumber=cttoolname OR csToolNumber=cttoolname WHERE csStn=px.getstation() ORDER BY cskey DESC LIMIT 1;
    IF FOUND THEN
      IF tn = 2 THEN -- The SPINE/EMBL tool
        SELECT cats.recover_SPINE_dismount_failure() INTO rtn;
      END IF;
    END IF;
    return rtn;
  END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;
ALTER FUNCTION cats.recover_dismount_failure() OWNER TO lsadmin;
