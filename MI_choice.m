classdef MI_choice
    properties
        fs=512; % WARNING: DO NOT change this. Amplifier acquisition rate can only be changed from its panel in Simulink, it is here for reference
        imgFolder='C:\Code\2018_10_MI_choice\Images';
        structsFolder='C:\Code\2018_10_MI_choice\TempImgStructs';
        questionsFile='questions.mat';
        questions;
        imgWidth;
        rawData;
        condition;
        figureParams;
        colorScheme;
        modelName;
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
    end
    properties (Dependent)
        currTime;
        screenRes;
    end
    properties (Hidden)
        CDlength;
        possibleConditions={'V feedback','VT feedback'};
        isExpClosed=0;
        isSerialPortOpen=0;
        isDebugging;
        motorSerialPort;
    end
    methods
        %% Constructor
        function obj=MI_choice
            % Some parameters (e.g. sampling frequency of amplifier and
            % buffer window length) cannot be changed directly from here,
            % so please do make sure that they're matching with the current
            % settings of relevant Simulink model.
            obj.isDebugging=1;
            
            % Set length of initial countdown, in seconds
            if obj.isDebugging
                obj.CDlength=2;
            else
                obj.CDlength=15;
            end
                        
            % Define timing parameters
            if obj.isDebugging
                obj.timingParams.blankLength=.5;
                obj.timingParams.questionLength=1;
                obj.timingParams.imgLength=1;
                obj.timingParams.feedbackLength=.5;
            else
                obj.timingParams.blankLength=2;
                obj.timingParams.questionLength=2;
                obj.timingParams.imgLength=3;
                obj.timingParams.feedbackLength=2;
            end
            obj.timingParams.updateTime=1/10;
            
            % Define chance of error during training
            if obj.isDebugging
                obj.errChance=1;
            else
                obj.errChance=0.3;
            end
            
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
                       
            % Define vibration intensities for different events
            obj.vibrationParams.MItrain=.7;
            obj.vibrationParams.feedback=1;
            
            % Initialize logs
            obj.outputLog.trialLog=[];
            
            % Ask user whether to start experiment right away
            clc;
            if ~strcmpi(input('Start experiment now? [Y/n]\n','s'),'n')
                obj=startExperiment(obj);
            end
        end
        
        % Other methods
        function obj=startExperiment(obj)
            % Variables on base workspace will be used to trigger closing
            % of experiment
            assignin('base','isExpClosing',0);
                        
            % Sets name of Simulink model to be used for acquisition
            obj.modelName='SimpleAcquisition_16ch_2014a_RT_preProc';
            
            % Load questions file
            q=load(obj.questionsFile,'questions');
            obj.questions=q.questions;
            
            % Prompts user to select a condition
            obj=selectCondition(obj);
            obj=setConditionSpecificParams(obj);
            
            % Load images to be used into memory
            obj=preprocessImages(obj);
            
            % Prepares serial port for vibrating motor control
            obj=obj.prepareSerialPort;
            
            % Prepares Simulink model (i.e. starts recording, basically)
            obj.prepareSimulinkModel;
            
            % Opens figure as background
            obj=createExpFigure(obj);
            
            % Generates array of time triggered events
            obj.timeTriggeredEvents{1}=timeTriggeredEvent('clearScreenCallback',0);
            obj.timeTriggeredEvents{2}=timeTriggeredEvent('presentQuestionCallback',Inf);
            obj.timeTriggeredEvents{3}=timeTriggeredEvent('presentImagesCallback',Inf);
            obj.timeTriggeredEvents{4}=timeTriggeredEvent('presentFeedbackCallback',Inf);
            obj.timeTriggeredEvents{5}=timeTriggeredEvent('updateCueCallback',Inf);
            
            % Shows a countdown
            obj.startCountdown(obj.CDlength);
            
            % Perform bulk of experiment
            obj=manageExperiment(obj);
            
            % Closes exp window and saves data
            obj.closeExp;
        end
        
        function obj=clearScreenCallback(obj)            
            % If vibrating bands are in use, stop vibration
            if obj.feedbackType==2
                fprintf(obj.motorSerialPort,'e12\n');
                pause(0.05);
                fprintf(obj.motorSerialPort,'r0\n');
            end

            % Log timing
            obj.timeTriggeredEvents{1}.triggersLog=[obj.timeTriggeredEvents{1}.triggersLog,obj.currTime];
            
            % Clear cursor, images and text, if present
            if isfield(obj.figureParams,'fig1Handle')
                delete(obj.figureParams.fig1Handle);
                delete(obj.figureParams.fig2Handle);
                delete(obj.figureParams.cursorHandle);
            end
            
            % Determine new couple of images to be displayed
            obj.trialInfo.nextCoupleInd=mod(length(obj.timeTriggeredEvents{3}.triggersLog),obj.trialsPerQuestion)+1;
            obj.trialInfo.nextCorrectInd=obj.questions.CorrectListIdx(obj.trialInfo.nextCoupleInd);
            obj.trialInfo.nextErrorInd=obj.questions.WrongListIdx(obj.trialInfo.nextCoupleInd);
            obj.trialInfo.correctPos=ceil(rand*2);
            obj.trialInfo.isFeedbackCorrect=rand>obj.errChance;
            
            % Log trial data generated above
            obj.outputLog.trialLog=cat(1,obj.outputLog.trialLog,obj.trialInfo);
            
            % Remove trigger for this event, set it for next
            obj.timeTriggeredEvents{1}.nextTrigger=Inf;
            if mod(length(obj.timeTriggeredEvents{3}.triggersLog),obj.trialsPerQuestion)==0
                obj.timeTriggeredEvents{2}.nextTrigger=obj.currTime+obj.timingParams.blankLength;
            else
                obj.timeTriggeredEvents{3}.nextTrigger=obj.currTime+obj.timingParams.blankLength;
            end
        end
        
        function obj=presentQuestionCallback(obj)
            % Log timing
            obj.timeTriggeredEvents{2}.triggersLog=[obj.timeTriggeredEvents{2}.triggersLog,obj.currTime];
            
            % Write question on screen
            obj.figureParams.textHandle=text(obj.screenRes(1)*.5,obj.screenRes(2)*.5,obj.questions.EnglishQuestion,'FontSize',64,'HorizontalAlignment','Center','VerticalAlignment','Middle');
            hold on;
            
            % Scramble list of answers for current question
            newOrder=randperm(length(obj.questions.CorrectListIdx));
            obj.questions.CorrectListIdx=obj.questions.CorrectListIdx(newOrder);
            obj.questions.WrongListIdx=obj.questions.WrongListIdx(newOrder);
            
            % Clear fixation cross, if present
            if isfield(obj.figureParams,'crossV')&&~isempty(obj.figureParams.crossV)
                delete(obj.figureParams.crossV);
                delete(obj.figureParams.crossH);
            end
            
            % Set triggers
            obj.timeTriggeredEvents{2}.nextTrigger=Inf;
            obj.timeTriggeredEvents{3}.nextTrigger=obj.currTime+obj.timingParams.questionLength;
        end
        
        function obj=presentImagesCallback(obj)
            % Log timing
            obj.timeTriggeredEvents{3}.triggersLog=[obj.timeTriggeredEvents{3}.triggersLog,obj.currTime];
            
            % Remove text, if present
            if isfield(obj.figureParams,'textHandle')&&~isempty(obj.figureParams.textHandle)
                delete(obj.figureParams.textHandle);
                obj.figureParams.textHandle=[];
            end 
            
            % Display images on screen
            img{obj.trialInfo.correctPos}=obj.imgStack(obj.trialInfo.nextCorrectInd).Img;
            img{3-obj.trialInfo.correctPos}=obj.imgStack(obj.trialInfo.nextErrorInd).Img;
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
            set(obj.figureParams.cursorHandle,'FaceAlpha',0.5);
            
            % Start progressive selection cue
            obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime;
            
            % Set triggers
            obj.timeTriggeredEvents{3}.nextTrigger=Inf;
            obj.timeTriggeredEvents{4}.nextTrigger=obj.currTime+obj.timingParams.imgLength;
        end
        
        function obj=updateCueCallback(obj)
            % Log timing
            obj.timeTriggeredEvents{5}.triggersLog=[obj.timeTriggeredEvents{5}.triggersLog,obj.currTime];
            
            % Set cursor pos
            cueDir=((obj.trialInfo.correctPos)-1.5)*2;
            relativeTimeElapsed=((obj.currTime-obj.timeTriggeredEvents{3}.triggersLog(end))/obj.timingParams.imgLength);
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
            obj.timeTriggeredEvents{5}.nextTrigger=obj.currTime+obj.timingParams.updateTime;
        end
        
        function obj=presentFeedbackCallback(obj)
            % Log timing
            obj.timeTriggeredEvents{4}.triggersLog=[obj.timeTriggeredEvents{4}.triggersLog,obj.currTime];
            
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
                if obj.trialInfo.correctPos==1
                    fprintf(obj.motorSerialPort,'e4\n');
                else
                    fprintf(obj.motorSerialPort,'e8\n');
                end
            end
            pause(0.05);
            fbVibrationValue=round(obj.vibrationParams.feedback*100);
            fprintf(obj.motorSerialPort,sprintf('r%d\n',fbVibrationValue));
            
            % Set triggers
            obj.timeTriggeredEvents{4}.nextTrigger=Inf;
            obj.timeTriggeredEvents{5}.nextTrigger=Inf;
            obj.timeTriggeredEvents{1}.nextTrigger=obj.currTime+obj.timingParams.feedbackLength;
        end
        
        function obj=manageExperiment(obj)
            % Generate file name used to save experiment data
            fileName=datestr(now,30);
            
            % Experiment control loop
%             try
            while ~evalin('base','isExpClosing')
                pause(0.001);
                for currTTevent=1:length(obj.timeTriggeredEvents)
                    obj=checkAndExecute(obj.timeTriggeredEvents{currTTevent},obj.currTime,obj);
                    pause(0.0001);
                end
            end
%             catch
%                 warning('Error occurred, closing exp early');
%             end
            pause(1);
            obj.isExpClosed=1;
            delete(gcf);
            set_param(obj.modelName,'SimulationCommand','Stop');
            set_param(obj.modelName,'StartFcn','')
            obj.rawData=evalin('base','rawData');
            save(fileName,'obj');
            
            % Stop vibration and close serial port communication
            if obj.isSerialPortOpen
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
            
            % Clear variables from base workspace
            evalin('base','clear listener*');
            evalin('base','clear toggleTraining');
        end
        
        function obj=preprocessImages(obj)
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
            load([obj.structsFolder,'\animali_struct.mat']);
            obj.imgStack=animali;
            for currImg=1:length(obj.imgStack)
                obj.imgStack(currImg).Img=imread([obj.imgFolder,'\',obj.imgStack(currImg).Category,'\',obj.imgStack(currImg).FileName]);
                obj.imgStack(currImg).Img=imresize(obj.imgStack(currImg).Img,obj.imgWidth/size(obj.imgStack(currImg).Img,2));
            end
        end
        
        function obj=createExpFigure(obj)
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
                'WindowKeyPressFcn',@KeyPressed,...
                'CloseRequestFcn',@OnClosing,...
                'WindowButtonMotionFcn',@onMouseMove);
            
            % Resize figure, then remove figure axis
            Pix_SS = get(0,'screensize');
            set(gcf,'position',Pix_SS);
            axis([0 Pix_SS(3) 0 Pix_SS(4)])
            set(gca,'YDir','reverse');
            axis('off')
        end
                                               
        function obj=selectCondition(obj)
            currCond=0;
            while true
                clc;
                for currPossibleCond=1:length(obj.possibleConditions)
                    fprintf('[%d] - %s;\n',currPossibleCond,obj.possibleConditions{currPossibleCond});
                end
                currCond=input('\nPlease select desired condition: ');
                if ismember(currCond,1:length(obj.possibleConditions));
                    break
                end
            end
            obj.condition.conditionID=currCond;
        end
        
        function obj=setConditionSpecificParams(obj)
            % 'V feedback','VT feedback'
            switch obj.condition.conditionID
                case 1
                    obj.feedbackType=1;
                case 2
                    obj.feedbackType=2;
            end
        end
        
        function prepareSimulinkModel(obj)
            % Check whether simulink model file can be found
            if ~exist(obj.modelName,'file')
                warning('Cannot find model %s.\nPress Enter to continue.\n',obj.modelName);
                input('');
                [fileName,pathName]=uigetfile('*.slx','Select Simulink model to load:');
                obj.modelName=sprintf('%s\\%s',pathName,fileName);
            end
            % Load model
            load_system(obj.modelName);
            
            % Check whether simulation was already running, and, in case,
            % stop it
            if bdIsLoaded(obj.modelName)&&strcmp(get_param(obj.modelName,'SimulationStatus'),'running')
                set_param(obj.modelName,'SimulationCommand','Stop');
            end
            
            % Add event listener to triggered buffer event.
            set_param(obj.modelName,'StartFcn',sprintf('simulinkModelStartFcn(''%s'')',obj.modelName))
            set_param(obj.modelName,'StopTime','inf');
            set_param(obj.modelName,'FixedStep',['1/',num2str(obj.fs)]);
            set_param(obj.modelName,'SimulationCommand','Start');
        end
        
        function obj=prepareSerialPort(obj)
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
        
        function wait(obj,pauseLength)
            startTime=get_param(obj.modelName,'SimulationTime');
            while strcmp(get_param(obj.modelName,'SimulationStatus'),'running')&&get_param(obj.modelName,'SimulationTime')<=startTime+pauseLength
                pause(1/(2*obj.fs));
            end
        end
        
        function startCountdown(obj,nSecs)
            % countdown to experiment start
            figure(obj.figureParams.handle)
            for cntDown=nSecs:-1:1
                if ~exist('textHandle','var')
                    textHandle=text(obj.screenRes(1)*.5,obj.screenRes(2)*.3,num2str(cntDown),'FontSize',64,'HorizontalAlignment','center');
                else
                    set(textHandle,'String',num2str(cntDown));
                end
                pause(1);
            end
            delete(textHandle);
        end
        %% Dependent properties
        function cTime=get.currTime(obj)
            if obj.isExpClosed
                cTime=obj.rawData.Time(end);
            else
                cTime=get_param(obj.modelName,'SimulationTime');
            end
        end
        
        function res=get.screenRes(~)
            res=get(0,'screensize');
            res=res(3:end);
        end
    end
    methods (Static)        
        function closeExp
            % Signals experiment to close
            assignin('base','isExpClosing',1);
        end
    end
end

function simulinkModelStartFcn(~) %#ok<DEFNU>
% Start function for Simulink model.
end

function onMouseMove(~,~)
% Makes mouse pointer invisible
if ~strcmp(get(gcf,'Pointer'),'custom')
    set(gcf,'PointerShapeCData',NaN(16));
    set(gcf,'Pointer','custom');
end
end

function KeyPressed(~,eventdata,~)
% This is called each time a keyboard key is pressed while the mouse cursor
% is within the window figure area
if strcmp(eventdata.Key,'escape')
    MI_choice.closeExp;
end
if strcmp(eventdata.Key,'p')
    keyboard;
    %     assignin('base','pauseNextTrial',1)
end
if strcmp(eventdata.Key,'t')
    assignin('base','toggleTraining',1);
end
if strcmp(eventdata.Key,'z')
    assignin('base','togglePause',1);
end
end

function OnClosing(~,~)
% Overrides normal closing procedure so that regardless of how figure is
% closed logged data is not lost
MI_choice.closeExp;
end