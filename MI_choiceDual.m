classdef MI_choiceDual < handle
    properties
        EEGsystem;
        fs=250; % WARNING: DO NOT change this. Amplifier acquisition rate can only be changed from its panel in Simulink, it is here for reference
        nChannels;
        imgFolder='C:\Code\2018_10_MI_choice\Images';
        structsFolder='C:\Code\2018_10_MI_choice\TempImgStructs';
        questionsFile='questions.mat';
        elMap;
        questionOrder;
        openParams;
        openCOMport;
        questions;
        imgWidth;
        condition;
        figureParams;
        colorScheme;
        modelName='SimpleAcquisition_16ch_2014a_RT_preProc'; % Will be ignored if gTec is not used
        timeTriggeredEvents;
        outputLog;
        recLength;
        timingParams;
        feedbackType; % 1 - no tactile feedback, 2 - tactile feedback
        vibrationParams;
        maxNtrials;
        imgStack;
        trialInfo;
        errChance;
        trialsPerQuestion=10;
        lastErrP_BACC;
        lastMI_BACC;
    end
    properties (Dependent)
        currTime;
        screenRes;
    end
    properties (Hidden)
        CDlength;
        possibleConditions={'OpenBCI, V feedback','OpenBCI, VT feedback','gTec, V feedback','gTec, VT feedback'};
        isExpClosed=0;
        isSerialPortOpen=0;
        isDebugging;
        motorSerialPort;
        fileName;
        shortTimer;
        listener;
        instanceName;
        currQuestion=0;
        isPausing=0;
        lastErrP_method;
        lastMI_method;
    end
    methods
        %% Constructor
        function obj=MI_choiceDual
            % Some parameters (e.g. sampling frequency of amplifier and
            % buffer window length) cannot be changed directly from here,
            % so please do make sure that they're matching with the current
            % settings of relevant Simulink model.
            obj.isDebugging=0;
            
            % Set length of initial countdown, in seconds
            if obj.isDebugging
                obj.CDlength=2;
                obj.maxNtrials=60;
            else
                obj.CDlength=15;
                obj.maxNtrials=400;
            end
                        
            % Define timing parameters
            if obj.isDebugging
                obj.timingParams.blankLength=.5;
                obj.timingParams.questionLength=1;
                obj.timingParams.imgLength=1;
                obj.timingParams.feedbackLength=.5;
                obj.timingParams.waitTime=0;
            else
                obj.timingParams.blankLength=1;
                obj.timingParams.questionLength=2;
                obj.timingParams.imgLength=3.5;
                obj.timingParams.feedbackLength=1;
                obj.timingParams.waitTime=0.5; % Cursor will not move for this duration after image is presented. Does not affect total time of image presentation!
            end
            obj.timingParams.updateTime=1/10;
            
            % Define chance of error during training
            if obj.isDebugging
                obj.errChance=1;
            else
                obj.errChance=0.3;
            end
            
            % Load electrode map from file
            obj.elMap=loadMap;
            
            % Set number of questions between pauses
            obj.timingParams.questionsBetweenPauses=8;
            
            % Set colors for different objects
            obj.colorScheme.bg=[.7,.7,.7];
            % Define color scheme
            obj.colorScheme.possibleColors={[.4,0,.1],[0,.4,0],[.8,.2,0],[.6,.6,0]};
            obj.colorScheme.targetColor=obj.colorScheme.possibleColors{1};
            obj.colorScheme.cursorColorMI=obj.colorScheme.possibleColors{2};
            obj.colorScheme.cursorColorRest=obj.colorScheme.possibleColors{4};
            obj.colorScheme.cursorColorReached=obj.colorScheme.possibleColors{3};
            obj.colorScheme.cursorColor=obj.colorScheme.cursorColorMI;
            obj.colorScheme.edgeColor=[.4,.4,.4];
            
            % Set cursor size
            obj.figureParams.cursorRadius=100;
            
            obj.figureParams.h=[];
                       
            % Define vibration intensities for different events
            obj.vibrationParams.MItrain=.7;
            obj.vibrationParams.feedback=1;
            
            % Define constants
            obj.nChannels=8;
            obj.openParams.wordLength=33; % Number of bytes each entry is composed of
            obj.openParams.bytePos{1}=3:3:2+3*obj.nChannels; % Position of bytes for each channel within words
            obj.openParams.bytePos{2}=obj.openParams.bytePos{1}+1;
            obj.openParams.bytePos{3}=obj.openParams.bytePos{1}+1;
            obj.openParams.inputBufferSize=obj.openParams.wordLength*obj.fs*10;
            
            % Initialize some log variables
            obj.outputLog.rawData=[];
            obj.outputLog.dataBuffer=[];
            obj.outputLog.sampleCount=[];
            obj.outputLog.timeLog=[];
            obj.outputLog.trialLog=[];
                        
%             % Ask user whether to start experiment right away
%             clc;
%             if ~strcmpi(input('Start experiment now? [Y/n]\n','s'),'n')
%                 startExperiment(obj);
%             end
        end
        
        % Other methods
        function startExperiment(obj)
            % I need to make sure that no other instances of this class are
            % present in base workspace, otherwise I will not be able to
            % make Simulink create a listener in the correct instance
            varList=evalin('base','whos');
            nCorrectClass=0;
            for currVar=1:length(varList)
                if strcmp(varList(currVar).class,mfilename)
                    nCorrectClass=nCorrectClass+1;
                    obj.instanceName=varList(currVar).name;
                    if nCorrectClass>1
                        warning('Please remove from workspace other variables of this class before starting experiment. Thanks!')
                        return;
                    end
                end
            end
            
            % I need to tell Simulink that the model was launched from
            % script instead of by itself
            assignin('base','isProperExp',1)
            
            % Determine name to be used to save file upon closing
            obj.fileName=datestr(now,30);

            % Load questions file
            q=load(obj.questionsFile,'questions');
            obj.questions=q.questions;
            
            % Prompts user to select a condition
            selectCondition(obj);
            setConditionSpecificParams(obj);
            
            % Load images to be used into memory
            preprocessImages(obj);
            
            % Prepares serial port for vibrating motor control
            obj.prepareSerialPort;
            
            % Prepares EEG acquisition
            if strcmp(obj.EEGsystem,'openBCI');
                obj.startRecording;
            else
                obj.prepareSimulinkModel;
            end
            
            % Opens figure as background
            createExpFigure(obj);
            
            % Shows a countdown
            obj.startCountdown(obj.CDlength);
            
            % Generates array of time triggered events
            functionNames={'clearScreenCallback','presentQuestionCallback','presentImagesCallback','presentFeedbackCallback','updateCueCallback'};
            nextTriggerTime=[Inf,Inf,Inf,Inf,Inf];
            for currEvent=1:length(functionNames)
                obj.timeTriggeredEvents(currEvent).eventMethod=functionNames{currEvent};
                obj.timeTriggeredEvents(currEvent).nextTrigger=nextTriggerTime(currEvent);
                obj.timeTriggeredEvents(currEvent).triggersLog=[];
            end
            
            % Start actual experiment
            obj.timeTriggeredEvents(1).nextTrigger=obj.currTime;
        end
        
        function clearScreenCallback(obj)
            % If vibrating bands are in use, stop vibration
            if obj.feedbackType==2
                fprintf(obj.motorSerialPort,'e12\n');
                pause(0.05);
                fprintf(obj.motorSerialPort,'r0\n');
            end

            % Log timing
            obj.timeTriggeredEvents(1).triggersLog=[obj.timeTriggeredEvents(1).triggersLog,obj.currTime];
            
            % Clear cursor, images and text, if present
            if isfield(obj.figureParams,'fig1Handle')
                delete(obj.figureParams.fig1Handle);
                delete(obj.figureParams.fig2Handle);
                delete(obj.figureParams.cursorHandle);
            end
            
            % If expected number of trials has been reached, close exp
            if length(obj.outputLog.trialLog)>=obj.maxNtrials
                obj.closeExp;
                return;
            end
                        
            % Randomly select questions order, if this is first pass
            if isempty(obj.questionOrder)
                obj.questionOrder=randperm(length(obj.questions));
            end
            
            % Determine new couple of images to be displayed
            obj.trialInfo.nextCoupleInd=mod(length(obj.timeTriggeredEvents(3).triggersLog),obj.trialsPerQuestion)+1;
            if obj.trialInfo.nextCoupleInd==1
                obj.currQuestion=obj.currQuestion+1;
                if obj.currQuestion>length(obj.questions)
                    obj.closeExp;
                    return;
                end
                % Scramble list of answers for current question
                newOrder=randperm(length(obj.questions(obj.questionOrder(obj.currQuestion)).CorrectListIdx));
                obj.questions(obj.questionOrder(obj.currQuestion)).CorrectListIdx=obj.questions(obj.questionOrder(obj.currQuestion)).CorrectListIdx(newOrder);
                obj.questions(obj.questionOrder(obj.currQuestion)).WrongListIdx=obj.questions(obj.questionOrder(obj.currQuestion)).WrongListIdx(newOrder);
            end
            obj.trialInfo.nextCorrectInd=obj.questions(obj.questionOrder(obj.currQuestion)).CorrectListIdx(obj.trialInfo.nextCoupleInd);
            obj.trialInfo.nextErrorInd=obj.questions(obj.questionOrder(obj.currQuestion)).WrongListIdx(obj.trialInfo.nextCoupleInd);
            obj.trialInfo.correctPos=ceil(rand*2);
            obj.trialInfo.isFeedbackCorrect=rand>obj.errChance;
            obj.trialInfo.currQuestion=obj.questionOrder(obj.currQuestion);
            
            % Log trial data generated above
            obj.outputLog.trialLog=cat(1,obj.outputLog.trialLog,obj.trialInfo);
            
            % Remove trigger for this event, set it for next
            obj.timeTriggeredEvents(1).nextTrigger=Inf;
            if mod(length(obj.timeTriggeredEvents(3).triggersLog),obj.trialsPerQuestion)==0
                obj.timeTriggeredEvents(2).nextTrigger=obj.currTime+obj.timingParams.blankLength;
            else
                obj.timeTriggeredEvents(3).nextTrigger=obj.currTime+obj.timingParams.blankLength;
            end
        end
        
        function presentQuestionCallback(obj)
            % Log timing
            obj.timeTriggeredEvents(2).triggersLog=[obj.timeTriggeredEvents(2).triggersLog,obj.currTime];
            
            % Write question on screen
            obj.figureParams.textHandle=text(obj.screenRes(1)*.5,obj.screenRes(2)*.5,obj.questions(obj.questionOrder(obj.currQuestion)).EnglishQuestion,'FontSize',64,'HorizontalAlignment','Center','VerticalAlignment','Middle');
            hold on;
            
            % Clear fixation cross, if present
            if isfield(obj.figureParams,'crossV')&&~isempty(obj.figureParams.crossV)
                delete(obj.figureParams.crossV);
                delete(obj.figureParams.crossH);
            end
            
            % Pause, if needed
            if mod(obj.currQuestion,obj.timingParams.questionsBetweenPauses)==0
                waitfor(warndlg('This is a pause, press OK to resume experiment.','Pause','modal'));
            end
            % Set triggers
            obj.timeTriggeredEvents(2).nextTrigger=Inf;
            obj.timeTriggeredEvents(3).nextTrigger=obj.currTime+obj.timingParams.questionLength;
        end
        
        function presentImagesCallback(obj)
            % Log timing
            obj.timeTriggeredEvents(3).triggersLog=[obj.timeTriggeredEvents(3).triggersLog,obj.currTime];
            
            % Remove text, if present
            if isfield(obj.figureParams,'textHandle')&&~isempty(obj.figureParams.textHandle)
                delete(obj.figureParams.textHandle);
                obj.figureParams.textHandle=[];
            end 
            
            % Display images on screen
            img{obj.trialInfo.correctPos}=obj.imgStack.(obj.questions(obj.questionOrder(obj.currQuestion)).CorrectListCategory{1})(obj.trialInfo.nextCorrectInd).Img;
            img{3-obj.trialInfo.correctPos}=obj.imgStack.(obj.questions(obj.questionOrder(obj.currQuestion)).WrongListCategory{1})(obj.trialInfo.nextErrorInd).Img;
            obj.figureParams.fig1Handle=imagesc(1/5*obj.screenRes(1)-obj.imgWidth*.5,0.5*obj.screenRes(2)-round(size(img{1},1)/2),img{1});
            obj.figureParams.fig2Handle=imagesc(4/5*obj.screenRes(1)-obj.imgWidth*.5,0.5*obj.screenRes(2)-round(size(img{2},1)/2),img{2});
            
            % Add fixation cross in the middle of the screen, if not
            % present
            if ~isfield(obj.figureParams,'crossV')||~ishghandle(obj.figureParams.crossV)
                obj.figureParams.crossV=patch([obj.screenRes(1)/2-10 obj.screenRes(1)/2+10 obj.screenRes(1)/2+10 obj.screenRes(1)/2-10],[obj.screenRes(2)/2-50 obj.screenRes(2)/2-50 obj.screenRes(2)/2+50 obj.screenRes(2)/2+50],'black');
                obj.figureParams.crossH=patch([obj.screenRes(1)/2-50 obj.screenRes(1)/2+50 obj.screenRes(1)/2+50 obj.screenRes(1)/2-50],[obj.screenRes(2)/2-10 obj.screenRes(2)/2-10 obj.screenRes(2)/2+10 obj.screenRes(2)/2+10],'black');
                set(obj.figureParams.crossV,'EdgeAlpha',1);
                set(obj.figureParams.crossH,'EdgeAlpha',1);
            end
            
            % Display cursor on screen
            cursorStartPosition=[0.5*obj.screenRes(1);0.5*obj.screenRes(2)];
            angles=linspace(1/40,1,40)*2*pi;
            cursorCoords=[cos(angles);sin(angles)]'*obj.figureParams.cursorRadius;
            xCoords=cursorStartPosition(1)+cursorCoords(:,1);
            yCoords=cursorStartPosition(2)+cursorCoords(:,2);
            obj.figureParams.cursorHandle=patch(xCoords,yCoords,'red');
            obj.figureParams.h = get(gca,'Children');
            set(gca,'Children',[obj.figureParams.h(1) obj.figureParams.h(2) obj.figureParams.h(5) obj.figureParams.h(3) obj.figureParams.h(4)]);
            set(obj.figureParams.cursorHandle,'FaceAlpha',0.5);
            drawnow;            
            
            % Start progressive selection cue
            obj.timeTriggeredEvents(5).nextTrigger=obj.currTime;
            
            % Set triggers
            obj.timeTriggeredEvents(3).nextTrigger=Inf;
            obj.timeTriggeredEvents(4).nextTrigger=obj.currTime+obj.timingParams.imgLength;
        end
        
        function updateCueCallback(obj)
            % Log timing
            obj.timeTriggeredEvents(5).triggersLog=[obj.timeTriggeredEvents(5).triggersLog,obj.currTime];
            
            % Set cursor pos
            cueDir=((obj.trialInfo.correctPos)-1.5)*2;
            relativeTimeElapsed=((max(0,obj.currTime-obj.timeTriggeredEvents(3).triggersLog(end)-obj.timingParams.waitTime))/(obj.timingParams.imgLength-obj.timingParams.waitTime));
            xStart=0.5*obj.screenRes(1);
            if cueDir<0
                xEnd=1/5*obj.screenRes(1);
            else
                xEnd=4/5*obj.screenRes(1);
            end
            currCenter=xStart+(xEnd-xStart)*relativeTimeElapsed^2;
            set(obj.figureParams.cursorHandle,'X',get(obj.figureParams.cursorHandle,'X')-mean(get(obj.figureParams.cursorHandle,'X'))+currCenter);
            
            % If vibrating bands are in use, set vibration level
            if obj.feedbackType==2
                if cueDir<0
                    fprintf(obj.motorSerialPort,'e4\n');
                else
                    fprintf(obj.motorSerialPort,'e8\n');
                end
                currVibrationValue=round(obj.vibrationParams.MItrain*relativeTimeElapsed^2*100);
                fprintf(obj.motorSerialPort,sprintf('r%d\n',currVibrationValue));
            end
            
            % Set triggers
            obj.timeTriggeredEvents(5).nextTrigger=obj.currTime+obj.timingParams.updateTime;
        end
        
        function presentFeedbackCallback(obj)
            % Log timing
            obj.timeTriggeredEvents(4).triggersLog=[obj.timeTriggeredEvents(4).triggersLog,obj.currTime];
            
            % Set cursor pos
            cueDir=((obj.trialInfo.correctPos)-1.5)*2*((obj.trialInfo.isFeedbackCorrect-.5)*2);
            if cueDir<0
                xEnd=1/5*obj.screenRes(1);
            else
                xEnd=4/5*obj.screenRes(1);
            end
            xCoords=get(obj.figureParams.cursorHandle,'X')-mean(get(obj.figureParams.cursorHandle,'X'));
            set(obj.figureParams.cursorHandle,'X',xCoords+xEnd,'FaceColor','green');
            
            % If vibrating bands are in use, stop vibration, then provide
            % correct feedback
            if obj.feedbackType==2
                fprintf(obj.motorSerialPort,'e12\n');
                pause(0.05);
                fprintf(obj.motorSerialPort,'r0\n');
                if cueDir~=1
                    fprintf(obj.motorSerialPort,'e4\n');
                else
                    fprintf(obj.motorSerialPort,'e8\n');
                end
            end
            pause(0.05);
            fbVibrationValue=round(obj.vibrationParams.feedback*100);
            fprintf(obj.motorSerialPort,sprintf('r%d\n',fbVibrationValue));
            
            % Set triggers
            obj.timeTriggeredEvents(4).nextTrigger=Inf;
            obj.timeTriggeredEvents(5).nextTrigger=Inf;
            obj.timeTriggeredEvents(1).nextTrigger=obj.currTime+obj.timingParams.feedbackLength;
        end
                
        function preprocessImages(obj)
%             % Loads all relevant images and names in a variable and resize
%             % them to acceptable dimensions
%             obj.imgWidth=2/5*obj.screenRes(1);
%             D=dir(obj.imgFolder);
%             obj.imgStack=cell(length(D)-2,1);
%             for currFile=3:length(D)
%                 obj.imgStack{currFile-2}.Name=D(currFile).name(1:end-6);
%                 obj.imgStack{currFile-2}.Img=imread([obj.imgFolder,'\',D(currFile).name]);
%                 obj.imgStack{currFile-2}.Img=imresize(obj.imgStack{currFile-2}.Img,obj.imgWidth/size(obj.imgStack{currFile-2}.Img,2));
%             end
            % Relevant images are already prepared in a matlab variable
            obj.imgWidth=1/4*obj.screenRes(1);
            D=dir(obj.structsFolder);
            for currStruct=3:length(D)
                fieldName=D(currStruct).name(1:end-11);
                load([obj.structsFolder,'/',D(currStruct).name]);
                eval(['currCategory=',fieldName,';']);
                for currImg=1:length(currCategory)
                    obj.imgStack.(fieldName)(currImg).Img=imread([obj.imgFolder,'\',currCategory(currImg).Category,'\',currCategory(currImg).FileName]);
                    obj.imgStack.(fieldName)(currImg).Img=imresize(obj.imgStack.(fieldName)(currImg).Img,obj.imgWidth/size(obj.imgStack.(fieldName)(currImg).Img,2));
                end
            end
        end
        
        function createExpFigure(obj)
            % Set figure properties
            obj.figureParams.handle=gcf;
            set(obj.figureParams.handle,'Tag',mfilename,...
                'Toolbar','none',...
                'MenuBar','none',...
                'Units','pixels',...
                'Resize','off',...
                'NumberTitle','off',...
                'Name','',...
                'Color',obj.colorScheme.bg,...
                'RendererMode','Manual',...
                'Renderer','OpenGL',...
                'WindowKeyPressFcn',@obj.KeyPressed,...
                'CloseRequestFcn',@obj.OnClosing,...
                'WindowButtonMotionFcn',@onMouseMove);
            
            % Resize figure, then remove figure axis
            Pix_SS = get(0,'screensize');
            set(gcf,'position',Pix_SS);
            axis([0 Pix_SS(3) 0 Pix_SS(4)])
            set(gca,'YDir','reverse');
            axis('off')
        end
                                               
        function selectCondition(obj)
            currCond=0;
            while true
                clc;
                for currPossibleCond=1:length(obj.possibleConditions)
                    fprintf('[%d] - %s;\n',currPossibleCond,obj.possibleConditions{currPossibleCond});
                end
                currCond=input('\nPlease select desired condition: ');
                if ismember(currCond,1:length(obj.possibleConditions))
                    break
                end
            end
            obj.condition.conditionID=currCond;
        end
        
        function setConditionSpecificParams(obj)
            % 'OpenBCI, V feedback','OpenBCI, VT feedback','gTec, V feedback','gTec, VT feedback'
            switch obj.condition.conditionID
                case 1
                    obj.EEGsystem='openBCI';
                    obj.feedbackType=1;
                    obj.fs=250;
                case 2
                    obj.EEGsystem='openBCI';
                    obj.feedbackType=2;
                    obj.fs=250;
                case 3
                    obj.EEGsystem='gTec';
                    obj.feedbackType=1;
                    obj.fs=512;
                    obj.nChannels=16;
                case 4
                    obj.EEGsystem='gTec';
                    obj.feedbackType=2;
                    obj.fs=512;
                    obj.nChannels=16;
            end
        end
        
        function startRecording(obj)
            % Create port object
            obj.openCOMport=serial('COM10','BaudRate',115200,'Timeout',.1,'Terminator','','InputBufferSize',obj.openParams.inputBufferSize);
            
            % Open serial communication (assuming relevant port is correct), reset
            % board and try to determine whether Daisy module is in use
            fopen(obj.openCOMport);
            pause(0.3);
            fprintf(obj.openCOMport,'s');
            pause(0.3);
            while obj.openCOMport.BytesAvailable>0
                fread(obj.openCOMport,obj.openCOMport.BytesAvailable); % Remove leftover data from previous runs, if present
                pause(0.1);
            end
            versionDump=[];
            while ~numel(strfind(versionDump,'DeviceID'))
                fprintf(obj.openCOMport,'v');
                while obj.openCOMport.BytesAvailable==0
                    pause(0.3);
                end
                versionDump=fscanf(obj.openCOMport,'%s',obj.openCOMport.BytesAvailable);
            end
            if numel(strfind(versionDump,'Daisy'))
                obj.openParams.isDaisyConnected=1;
                obj.nChannels=16;
                obj.fs=125;
                fprintf('Daisy connected. N electrodes = 16\n');
            else
                obj.openParams.isDaisyConnected=0;
                fprintf('Daisy not connected. N electrodes = 8\n');
            end
            obj.openParams.readSize=obj.openParams.wordLength*ceil(obj.fs*5); % WANRING: apparently, the board sends data in packets with about 480 ms worth of data...
            
%             % Set gain for for all channels
%             chIDchars='12345678QWERTYUI';
%             for currCh=1:obj.nChannels
%                 fprintf(obj.openCOMport,'x%s060110X',chIDchars(currCh));
%                 while obj.openCOMport.BytesAvailable==0
%                     pause(1);
%                 end
%                 fprintf('%s\n',fread(obj.openCOMport,obj.openCOMport.BytesAvailable));
%             end
            
            % fprintf(S,'5 6 7 8 q w e r t y u i');
%             pause(0.1);
            
            % Associates events needed and start data stream
            fclose(obj.openCOMport);
            obj.openCOMport.BytesAvailableFcnMode='byte';
            obj.openCOMport.BytesAvailableFcnCount=obj.openParams.readSize;
            obj.openCOMport.BytesAvailableFcn={@obj.readDataCallback};
            fopen(obj.openCOMport);
            pause(0.5);
            fprintf(obj.openCOMport,'b');
        end
        
        function prepareSimulinkModel(obj)
            % Check whether simulink model file can be found
            if ~exist(obj.modelName,'file')
                warning('Cannot find model %s.\nPress Enter to continue.\n',obj.modelName);
                input('');
                [fName,pathName]=uigetfile('*.slx','Select Simulink model to load:');
                obj.modelName=sprintf('%s\\%s',pathName,fName);
            end
            % Load model
            load_system(obj.modelName);
            
            % Check whether simulation was already running, and, in case,
            % stop it
            if bdIsLoaded(obj.modelName)&&strcmp(get_param(obj.modelName,'SimulationStatus'),'running')
                set_param(obj.modelName,'SimulationCommand','Stop');
            end
            
            % Add event listener to triggered buffer event.
            set_param(obj.modelName,'StartFcn',sprintf('simulinkModelStartFcn(''%s'',''%s'')',obj.modelName,obj.instanceName))
            set_param(obj.modelName,'StopFcn',sprintf('%s.simulinkModelStopFcn(''%s'',''%s'')',mfilename,obj.instanceName,obj.fileName))
            set_param(obj.modelName,'StopTime','inf');
            set_param(obj.modelName,'FixedStep',['1/',num2str(obj.fs)]);
            set_param(obj.modelName,'SimulationCommand','Start');
        end
        
        function prepareSerialPort(obj)
            obj.motorSerialPort=serial('COM9','BaudRate',230400,'Parity','even');
            try
                fopen(obj.motorSerialPort);
                pause(1);
                fprintf(obj.motorSerialPort,'e4\n');
                pause(0.3);
                fprintf(obj.motorSerialPort,'p\n');
                pause(0.3);
                fprintf(obj.motorSerialPort,'e8\n');
                pause(0.3);
                fprintf(obj.motorSerialPort,'p\n');
                pause(0.3);
                obj.isSerialPortOpen=1;
            catch
                warning('Unable to open serial port communication with band motors');
            end
        end
        
        function startCountdown(obj,nSecs)
            % countdown to experiment start
            figure(obj.figureParams.handle)
            for cntDown=nSecs:-1:1
                if ~exist('textHandle','var')
                    textHandle=text(obj.screenRes(1)*.5,obj.screenRes(2)*.3,num2str(cntDown),'FontSize',64,'HorizontalAlignment','center');
                else
                    if ~ishghandle(textHandle) %i.e. figure was closed during countdown
                        return
                    else
                        set(textHandle,'String',num2str(cntDown));
                    end
                end
                pause(1);
            end
            delete(textHandle);
        end
        
        function readDataCallback(obj,S,~)
            % Check number of available data
            availableBytes=S.BytesAvailable;
            if availableBytes % Multiple calls to this function might cause this to be false, at this point
                % Print warning message if buffer is starting to fill up
                bufferFill=availableBytes./obj.openParams.inputBufferSize;
                if bufferFill>.8 %#ok<BDSCI>
                    fprintf('WARNING: buffer full at %0.2f%%',bufferFill*100);
                end
                
                % Read available data
                inData=fread(S,availableBytes);
                obj.outputLog.dataBuffer=cat(1,obj.outputLog.dataBuffer,inData);
                
                % Check that buffer start is correct
                while (length(obj.outputLog.dataBuffer)>=obj.openParams.wordLength)&&~(obj.outputLog.dataBuffer(1)==160&&obj.outputLog.dataBuffer(obj.openParams.wordLength)==192) % The second value WILL change when time logging is going to work
                    % Word is incomplete, should only occur at the beginning of
                    % transmission. Remove old data until the beginning of a new
                    % word is found
                    obj.outputLog.dataBuffer(1)=[];
                end
                
                % Read everything else left on buffer in one go, minus possible partial
                % word at the end
                nWords=floor(length(obj.outputLog.dataBuffer)/obj.openParams.wordLength);
                
                % Leave one word on buffer if their number is odd, as an even number of
                % words is required if Daisy is attached and it doesn't make much of a
                % difference if it isn't
                if mod(nWords,2)==1
                    nWords=nWords-1;
                end
                
                % Parse data read from buffer
                newEntries=reshape(obj.outputLog.dataBuffer(1:nWords*obj.openParams.wordLength),obj.openParams.wordLength,nWords);
                obj.outputLog.dataBuffer(1:nWords*obj.openParams.wordLength)=[];
                tempData=zeros(3,8,nWords);
                for currByte=1:3
                    tempData(currByte,:,:)=newEntries(obj.openParams.bytePos{currByte},:);
                end
                newData=squeeze(sum(tempData.*repmat(256.^(2:-1:0)',1,8,nWords)))';
                newData(newData>=256^3/2)=newData(newData>=256^3/2)-256^3;
                newSampleCounts=newEntries(2,:)';
                
                % Remove erroneous entries (this should not happen)
                toBeRemoved=~ismember(diff(newSampleCounts),[1 -255]);
                newSampleCounts(toBeRemoved)=[];
                newData(toBeRemoved,:)=[];
                if sum(toBeRemoved)
                    fprintf('Warning: potential data loss occurred\n');
                    return
                end
                if obj.openParams.isDaisyConnected
                    newData=[newData(mod(newSampleCounts,2)==1,:),newData(mod(newSampleCounts,2)==0,:)];
                end
                
                % Update logs
                obj.outputLog.sampleCount=cat(1,obj.outputLog.sampleCount,newSampleCounts);
                if obj.openParams.isDaisyConnected
                    obj.outputLog.timeLog=cat(1,obj.outputLog.timeLog,((length(obj.outputLog.timeLog)+1:length(obj.outputLog.timeLog)+nWords/2)/obj.fs)');
                else
                    obj.outputLog.timeLog=cat(1,obj.outputLog.timeLog,((length(obj.outputLog.timeLog)+1:length(obj.outputLog.timeLog)+nWords)/obj.fs)');
                end
                obj.outputLog.rawData=cat(1,obj.outputLog.rawData,newData);
                tic;

                % Start timer to check for events with higher time
                % resolution
                if isempty(obj.shortTimer)
                    obj.shortTimer=timer('BusyMode','Drop','ExecutionMode','fixedRate','Period',0.01,'TimerFcn',@obj.timeTriggersCheck,'Name','shortTimer');
                else
                    stop(obj.shortTimer);
                end
                start(obj.shortTimer);
            end
        end
        
        function timeTriggersCheck(obj,~,~)
            % Test whether any time-triggered events should fire
            for currEvent=1:length(obj.timeTriggeredEvents)
                if obj.currTime>=obj.timeTriggeredEvents(currEvent).nextTrigger
                    obj.(obj.timeTriggeredEvents(currEvent).eventMethod);
                end
            end
        end
        
        function KeyPressed(obj,~,eventdata,~)
            % This is called each time a keyboard key is pressed while the mouse cursor
            % is within the window figure area
            if strcmp(eventdata.Key,'escape')
                obj.closeExp;
            end
            if strcmp(eventdata.Key,'p')
                if strcmp(obj.EEGsystem,'gTec')
                    if obj.isPausing
                        obj.isPausing=0;
                        set_param(obj.modelName,'SimulationCommand','Continue');
                    else
                        obj.isPausing=1;
                        set_param(obj.modelName,'SimulationCommand','Pause');
                    end
                else
                    keyboard;
                end
            end
        end
        
        function closeExp(obj,~,~)           
            % Prevent further events from triggering
            nextTriggerTime=[Inf,Inf,Inf,Inf,Inf];
            for currEvent=1:length(nextTriggerTime)
                obj.timeTriggeredEvents(currEvent).nextTrigger=nextTriggerTime(currEvent);
            end
            
            % Close figure
            delete(gcf);
            
            % Stop vibration and close serial port communication
            try
                if isvalid(obj.isSerialPortOpen)
                    fprintf(obj.motorSerialPort,'e8\n');
                    pause(0.003)
                    fprintf(obj.motorSerialPort,'p\n');
                    pause(0.003)
                    fprintf(obj.motorSerialPort,'r0\n');
                    pause(0.003)
                    fprintf(obj.motorSerialPort,'e4\n');
                    pause(0.003)
                    fprintf(obj.motorSerialPort,'p\n');
                    pause(0.003)
                    fprintf(obj.motorSerialPort,'r0\n');
                    fclose(obj.motorSerialPort);
                    delete(obj.motorSerialPort);
                end
            catch
                warning('Problem with closing vibration serial port. Close it manually before starting new experiment.');
            end
            
            % Stop data acquisition
            if strcmp(obj.EEGsystem,'openBCI')
                stop(obj.shortTimer);
                fclose(obj.openCOMport);
                delete(obj.openCOMport);
                                            
                % Save data and declare exp closed (this is rather ugly. Is
                % there a better way of doing it?)
                eval(sprintf('%s=obj',obj.instanceName));
                save(obj.fileName,obj.instanceName);
            else
                obj.listener=[];
                set_param(obj.modelName,'SimulationCommand','Stop');
                set_param(obj.modelName,'StartFcn','');
            end
            obj.isExpClosed=1;
        end
        
        function OnClosing(obj,~,~)
            % Overrides normal closing procedure so that regardless of how figure is
            % closed logged data is not lost
            obj.closeExp;
        end
        
        %% Analysis methods
        function offlineErrP(obj)
            % Apply spatial filters
            [B,A]=cheby1(2,6,[.2,10]/(obj.fs/2));
            lapData=obj.applyLapFilter(obj.outputLog.rawData);
            freqData=filter(B,A,lapData);
            
            % Normalize data
            normalize=@(x)(x-repmat(mean(x),size(x,1),1))./repmat(1.4826*mad(x,1),size(x,1),1);
            normData=normalize(freqData);
            
            % Recover lbls and signal windows
            lbls=cell2mat({obj.outputLog.trialLog(1:min(obj.maxNtrials,length(obj.outputLog.trialLog)-1)).isFeedbackCorrect})';
            relWins=zeros(length(lbls),obj.fs*(obj.timingParams.feedbackLength),size(obj.outputLog.rawData,2));
            for currWin=1:size(relWins,1)
                relWins(currWin,:,:)=normData(round((obj.timeTriggeredEvents(4).triggersLog(currWin))*obj.fs+1:(obj.timeTriggeredEvents(4).triggersLog(currWin)+obj.timingParams.feedbackLength)*obj.fs),:);
            end
            
            % Recover features and perform classification
            [freqFeats,timeFeats]=MI_choiceDual.preprocessData(relWins);
            allFeats=[reshape(freqFeats,size(freqFeats,1),[],1),reshape(timeFeats,size(timeFeats,1),[],1)];
            
            % Compute results and log method employed
            [~,~,obj.lastErrP_BACC]=testClassifier2(lbls,allFeats,'blocktype','subsequent','nblocks',10,'threshold',.3,'selectionType','zScore','classifiertype','svm');
            tempStack=dbstack;
            obj.lastErrP_method=tempStack.name;
        end
        
        function offlineKarcherErrP(obj)
            % Apply spatial filters
            [B,A]=cheby1(2,6,[.2,10]/(obj.fs/2));
            lapData=obj.applyLapFilter(obj.outputLog.rawData);
            freqData=filter(B,A,lapData);
            
            % Recover lbls and signal windows
            lbls=cell2mat({obj.outputLog.trialLog(1:min(obj.maxNtrials,length(obj.outputLog.trialLog)-1)).isFeedbackCorrect})';
            relWins=zeros(length(lbls),obj.fs*(obj.timingParams.feedbackLength),size(obj.outputLog.rawData,2));
            for currWin=1:size(relWins,1)
                relWins(currWin,:,:)=freqData(round((obj.timeTriggeredEvents(4).triggersLog(currWin))*obj.fs+1:(obj.timeTriggeredEvents(4).triggersLog(currWin)+obj.timingParams.feedbackLength)*obj.fs),:);
            end
            
            % Cannot simply use testClassifier, as this algorithm is rather
            % different from standard ones
            C.NumTestSets=10;
            C.groups=ceil(linspace(1/length(lbls),C.NumTestSets,length(lbls)));
            C.training=@(currGroup)C.groups~=currGroup;
            C.test=@(currGroup)C.groups==currGroup;
            classEst=zeros(length(lbls),1);
            testAcc=@(x,y)(sum((x==1).*(y==1))./sum(x==1)+sum((x==0).*(y==0))./sum(x==0))*.5;
            for currP=1:C.NumTestSets
                % Recover training and testing sets
                trainData=relWins(C.training(currP),:,:);
                trainLbls=lbls(C.training(currP));
                testLbls=lbls(C.test(currP));
                
                % Compute class means
                classTags=unique(lbls);
                classMeans=zeros(length(classTags),size(relWins,2),size(relWins,3));
                for currClass=1:length(classTags)
                    classMeans(currClass,:,:)=mean(trainData(trainLbls==classTags(currClass),:,:));
                end
                
                % Construct super-trials
                superTrainFeats=zeros(size(relWins,1),size(relWins,2),size(relWins,3)*(length(classTags)+1));
                for currTrial=1:size(relWins,1)
                    superTrainFeats(currTrial,:,:)=cat(2,reshape(permute(classMeans,[1,3,2]),[],size(relWins,2))',squeeze(relWins(currTrial,:,:)));
                end
                
                % Compute covariance matrices
                covMats=cell(length(lbls),1);
                for currTrial=1:length(covMats)
                    covMats{currTrial}=cov(squeeze(superTrainFeats(currTrial,:,:)));
                    % Only relevant portion of the covariance matrix is the
                    % bottom left Nx2N section (N = number of recording
                    % channels)
                    covMats{currTrial}=covMats{currTrial}(end-obj.nChannels+1:end,1:2*obj.nChannels);
                    covMats{currTrial}=reshape(covMats{currTrial},1,size(covMats{currTrial},1),size(covMats{currTrial},2));
                end
                
                % Recover training and testing sets (again)
                trainData=reshape(cell2mat(covMats(C.training(currP))),length(trainLbls),[]);
                testData=reshape(cell2mat(covMats(C.test(currP))),length(testLbls),[]);
                
                % Perform SVM on resulting matrices
                clsfr.clsfr=fitcsvm(trainData,trainLbls,'Standardize',true,'KernelScale','auto','KernelFunction','polynomial','PolynomialOrder',2);
                clsfr.predict=@(x)clsfr.clsfr.predict(x);
                
                % Perform prediction for training and testing sets
                classEst(C.test(currP))=clsfr.predict(testData);
                trainClassEst=clsfr.predict(trainData);
                fprintf('Fold %d/%d BACC: train: %0.2f; test: %0.2f\n',currP,C.NumTestSets,testAcc(trainLbls,trainClassEst),testAcc(testLbls,classEst(C.test(currP))));
            end
            
            % Estimate CV BACC
            cvAcc=testAcc(lbls,classEst);
            fprintf('\nCross-val BACC: test: %0.2f\n',cvAcc);
        end
        
        function offlineMI(obj)
            % Normalize data
            normalize=@(x)(x-repmat(mean(x),size(x,1),1))./repmat(1.4826*mad(x,1),size(x,1),1);
            normData=normalize(obj.outputLog.rawData);
            
            % Apply spatial and temporal filters
            [B,A]=cheby1(4,6,[1,30]/(obj.fs/2));
            lapData=obj.applyLapFilter(filter(B,A,normData));
            
            % Recover lbls and signal windows
            lbls=cell2mat({obj.outputLog.trialLog(1:min(obj.maxNtrials,length(obj.outputLog.trialLog)-1)).correctPos})';
            errPlength=obj.timingParams.imgLength-obj.timingParams.waitTime;
            relWins=zeros(length(lbls),obj.fs*errPlength,size(obj.outputLog.rawData,2));
            for currWin=1:size(relWins,1)
                relWins(currWin,:,:)=lapData(round(obj.timeTriggeredEvents(3).triggersLog(currWin))*obj.fs+1:round(obj.timeTriggeredEvents(3).triggersLog(currWin)+errPlength)*obj.fs,:);
            end
            
            % Recover features and perform classification
            [freqFeats,timeFeats]=MI_choiceDual.preprocessData(relWins);
            allFeats=[reshape(freqFeats,size(freqFeats,1),[],1),reshape(timeFeats,size(timeFeats,1),[],1)];
            
            % Reduce large-scale artefacts
            for currFeat=1:size(allFeats,2)
                featsMAD=mad(allFeats(:,currFeat),1);
                allFeats(:,currFeat)=atan(allFeats(:,currFeat)/(3*featsMAD))*(3*featsMAD);
            end
            
            % Compute results and log method employed
            [~,~,obj.lastMI_BACC]=testClassifier2(lbls-1,allFeats,'blocktype','subsequent','nblocks',10,'threshold',.35,'selectionType','zScore','classifiertype','logistic');
            tempStack=dbstack;
            obj.lastMI_method=tempStack.name;
        end
        
        function offlineKarcherMI(obj)
            % Apply temporal filters
            [B,A]=cheby1(4,6,[8,30]/(obj.fs/2));
            freqData=filter(B,A,obj.outputLog.rawData);
            
            % Recover lbls and signal windows
            lbls=cell2mat({obj.outputLog.trialLog(1:min(obj.maxNtrials,length(obj.outputLog.trialLog)-1)).correctPos})';
            errPlength=obj.timingParams.imgLength-obj.timingParams.waitTime;
            relWins=zeros(length(lbls),obj.fs*errPlength,size(obj.outputLog.rawData,2));
            for currWin=1:size(relWins,1)
                relWins(currWin,:,:)=freqData(round(obj.timeTriggeredEvents(3).triggersLog(currWin))*obj.fs+1:round(obj.timeTriggeredEvents(3).triggersLog(currWin)+errPlength)*obj.fs,:);
            end
            
            % Compute results and log method employed
            [~,~,obj.lastMI_BACC]=testClassifier2(lbls-1,relWins,'blocktype','subsequent','nblocks',10,'classifiertype','karcher');
            tempStack=dbstack;
            obj.lastMI_method=tempStack.name;
        end
        
        function [outData,fltrWeights]=applyLapFilter(obj,inData)
            fltrWeights=zeros(size(inData,2));
            for currEl=1:size(inData,2)
                neighborsMap=zeros(size(obj.elMap.elMat));
                neighborsMap(obj.elMap.elMat==currEl)=1;
                neighborsMap=imdilate(neighborsMap,strel('diamond',1));
                neighborsMap(obj.elMap.elMat==currEl)=0;
                validNeighbors=logical(neighborsMap.*obj.elMap.elMat);
                fltrWeights(currEl,obj.elMap.elMat(validNeighbors))=-1/sum(sum(validNeighbors));
                fltrWeights(currEl,currEl)=1;
            end
            outData=inData*fltrWeights';
        end
        
        %% Dependent properties
        function cTime=get.currTime(obj)
            if strcmp(obj.EEGsystem,'openBCI')
                if isfield(obj.outputLog,'timeLog')&&~isempty(obj.outputLog.timeLog)
                    cTime=obj.outputLog.timeLog(end)+toc;
                else
                    cTime=0;
                end
            else
                cTime=get_param(obj.modelName,'SimulationTime');
            end
            if obj.isExpClosed
                if isempty(obj.outputLog.timeLog)
                    cTime=0;
                else
                    cTime=obj.outputLog.timeLog(end);
                end
            end
        end
        
        function res=get.screenRes(~)
            res=get(0,'screensize');
            res=res(3:end);
        end
    end
    methods (Static)
        function simulinkModelStopFcn(instanceName,fileName)
            if evalin('base','exist(''isProperExp'',''var'')')
                commandString=sprintf('%s.outputLog.rawData=rawData;\n%s.outputLog.timeLog=%s.outputLog.rawData.Time;\n%s.outputLog.rawData=%s.outputLog.rawData.Data;\nsave(''%s'',''%s'');\nclear isProperExp',instanceName,instanceName,instanceName,instanceName,instanceName,fileName,instanceName);
                evalin('base',commandString);
            end
        end
        
        %% Analysis methods
        function [freqFeats,timeFeats]=preprocessData(dataWins)
            % This function takes either one time window as input (during
            % testing) or a vector of them (during training). Reshape
            % single window to make it consistent
            if length(size(dataWins))==2
                dataWins=reshape(dataWins,1,size(dataWins,1),size(dataWins,2));
            end
            [nWins,~,nChs]=size(dataWins);
            timeFeats=zeros(size(dataWins,1),round(size(dataWins,2)/8),size(dataWins,3));
            freqFeats=zeros(nWins,129,nChs);
            % Preprocess each input window
            for currWin=1:nWins
                for currCh=1:nChs
                    relData=squeeze(dataWins(currWin,:,currCh));
                    % Normalize: set sd to 1
                    relData=relData/std(relData);
                    % Remove linear trend
                    relData=detrend(relData);
                    timeFeats(currWin,:,currCh)=resample(relData,64,512); % Resample time features at 64Hz (assuming a 512Hz original sampling rate)
                    % Compute bandpower
                    currOrder=16;
                    success=0;
                    while ~success
                        try %#ok<TRYNC>
                            freqFeats(currWin,:,currCh)=pyulear(relData.*blackman(length(relData))',currOrder);
                        end
                        success=1;
                    end
                end
            end
            % Consider only frequencies up to ~60Hz
            freqFeats(:,31:end,:)=[];
            % Extract logs
            freqFeats=log(freqFeats);
        end
    end
end

function onMouseMove(~,~)
% Makes mouse pointer invisible
if ~strcmp(get(gcf,'Pointer'),'custom')
    set(gcf,'PointerShapeCData',NaN(16));
    set(gcf,'Pointer','custom');
end
end

function simulinkModelStartFcn(modelName,instanceName) %#ok<DEFNU>
% Start function for Simulink model
blockName=sprintf('%s/g.USBamp UB-2016.03.10',modelName);
commandString=sprintf('%s.listener=add_exec_event_listener(''%s'',''PostOutputs'',@%s.timeTriggersCheck);',instanceName,blockName,instanceName);
evalin('base',commandString);
% assignin('base','listenerErrP',add_exec_event_listener(blockName,'PostOutputs',@simClock));
end