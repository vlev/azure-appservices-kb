#!/usr/bin/env bash

# NOTE: This script has to be sourced for it to work (Refer script's documentation for more details)
source /bin/appservice_helper.sh
install_signal_handlers

cat >/etc/motd <<EOL 
   _|_|                                            
 _|    _|  _|_|_|_|  _|    _|  _|  _|_|    _|_|    
 _|_|_|_|      _|    _|    _|  _|_|      _|_|_|_|  
 _|    _|    _|      _|    _|  _|        _|        
 _|    _|  _|_|_|_|    _|_|_|  _|          _|_|_|

     J A V A   O N   A P P   S E R V I C E

Documentation: https://aka.ms/appservice

**NOTE**: No files or system changes outside of /home will persist beyond your application's current session. /home is your application's persistent storage and is shared across all the server instances.


EOL
cat /etc/motd

# BEGIN: Initialize ssh daemon as early as possible

echo Updating /etc/ssh/sshd_config to use PORT $SSH_PORT
sed -i "s/SSH_PORT/$SSH_PORT/g" /etc/ssh/sshd_config

echo Starting ssh service...
ssh-keygen -A
service ssh start
service ssh status

# We want all ssh sesions to start in the /home directory
echo "cd /home" >> /etc/profile

# END: Initialize ssh daemon as early as possible 

# Print build info
echo "## Printing build info..."
cat /usr/local/appservice/packages.txt
echo "## Done printing build info."

# Print container info
print_container_info

# JAVA_HOME may be pointing to either a JDK installation or a JRE installation directory
# Get JRE_HOME by inspecting the presence of a jre sub-directory
if [ -d "${JAVA_HOME}/jre" ]
then
    export JRE_HOME="${JAVA_HOME}/jre"
else
    export JRE_HOME="${JAVA_HOME}"
fi

# Enable case-insensitive string matching
shopt -s nocasematch

# COMPUTERNAME will be defined uniquely for each worker instance while running in Azure.
# If COMPUTERNAME isn't available, we assume that the container is running in a dev environment.
# If running in dev environment, define required environment variables.
if [ -z "$COMPUTERNAME" ]
then
    export COMPUTERNAME=dev

    # BEGIN: AzMon related configuration

    export WEBSITE_HOSTNAME=dev.appservice.com
    export DIAGNOSTIC_LOGS_MOUNT_PATH=/var/log/diagnosticLogs
    
    # END: AzMon related configuration
fi

# Variables in logging.properties aren't being evaluated, so explicitly update logging.properties with the appropriate values
sed -i "s/__PLACEHOLDER_COMPUTERNAME__/$COMPUTERNAME/" /usr/local/appservice/logging.properties

# $DIAGNOSTIC_LOGS_MOUNT_PATH contains the backslash. 
sed -i "s@__PLACEHOLDER_DIAGNOSTIC_LOGS_MOUNT_PATH__@$DIAGNOSTIC_LOGS_MOUNT_PATH@" /usr/local/appservice/logging.properties

# BEGIN: Configure Spring Boot properties
# Precedence order of properties can be found here: https://docs.spring.io/spring-boot/docs/current/reference/html/boot-features-external-config.html

export JAVA_OPTS="$JAVA_OPTS -Dserver.port=$PORT"
export SERVER_PORT=$PORT

# Increase the default size so that Easy Auth headers don't exceed the size limit
export SERVER_MAXHTTPHEADERSIZE=16384

if [ -z $AZURE_LOGGING_DIR ]
then
    AZURE_LOGGING_DIR=/home/LogFiles
fi

# Spring boot uses LOGGING_FILE_NAME to specify the spring boot log file
# In previous iterations, we set LOGGING_FILE instead
# To get Spring boot logging working out of the box, add LOGGING_FILE_NAME
# To prevent regressing customers that may be using LOGGING_FILE, keep this with the same values

export LOGGING_FILE_NAME=$AZURE_LOGGING_DIR/Application/spring.$COMPUTERNAME.log

export LOGGING_FILE=$AZURE_LOGGING_DIR/Application/spring.$COMPUTERNAME.log

# END: Configure Spring Boot properties

# BEGIN: Configure KeyStore
configure_java_keystore
# END: Configure KeyStore

# BEGIN: Configure Java properties
configure_java_error_handlers

# BEGIN: Global JAVA properties.
# We want to allow them to be overridden using app settings.
# To ensure this, we append the default values instead of prepending them.

export JAVA_TOOL_OPTIONS="-Djava.net.preferIPv4Stack=true $JAVA_TOOL_OPTIONS"

# BEGIN: Configure Max Heap 
configure_java_heap
# END: Configure Max Heap 

# END: Global JAVA properties.

# END: Configure Java properties

# BEGIN: Write env vars to /etc/profile (as late as possible, to capture all vars defined in this file)

eval $(printenv | sed -n "s/^\([^=]\+\)=\(.*\)$/export \1=\2/p" | sed 's/"/\\\"/g' | sed '/=/s//="/' | sed 's/$/"/' >> /etc/profile)

# END: Write env vars to /etc/profile (as late as possible, to capture all vars defined in this file)

# For Java SE, we want to exit after running the startup script
# So, set GLOBAL_EXIT_AFTER_CUSTOM_STARTUP=1 and then call perform_custom_startup()
export GLOBAL_EXIT_AFTER_CUSTOM_STARTUP=1
perform_custom_startup "$@"

#Begin: Select jar file to run

# Gets the jar file name based on the following logic

# 1. If app.jar exists on wwwroot, use that 
# 2. Else, if there is only one jar in wwwroot, run that jar
# 3. Else, check each jar on wwwroot for an entry point, if only one is executable, run that one
# 4. Else, run the first one alphabetically and warn the user
java_copy_app_files


# Get a colon separated list of jars for adding to CLASSPATH.
# NOTE: We need to get a colon separated list because CLASSPATH=*.jar does not work
# If /home/site/libs does not exist or if it is empty, APPSERVICE_EXTERNAL_JARS will evaluate to an empty string, which is OK.
APPSERVICE_EXTERNAL_JARS=`ls -1d /home/site/libs/*.jar 2> /dev/null | tr '\n' ':'`

# Get the app.jar entry point using the JarEntryPointParser class
APPSERVICE_MANGLED_MAIN_CLASS_NAME=`java -cp /usr/local/appservice/lib/azure.appservice.jar com.microsoft.azure.appservice.JarEntryPointParser $APP_JAR_PATH`

echo "Mangled result from Jar entry point parser is: ${APPSERVICE_MANGLED_MAIN_CLASS_NAME}" 

# Extract the specific line that contains the jar entry point info
APPSERVICE_MANGLED_MAIN_CLASS_NAME=`echo "${APPSERVICE_MANGLED_MAIN_CLASS_NAME}" | grep __COM_MICROSOFT_AZURE_APPSERVICE_JARENTRYPOINT_PREFIX__ | grep __COM_MICROSOFT_AZURE_APPSERVICE_JARENTRYPOINT_SUFFIX__`

# Strip off the prefix
APPSERVICE_MANGLED_MAIN_CLASS_NAME=`echo "${APPSERVICE_MANGLED_MAIN_CLASS_NAME}" | sed 's/.*__COM_MICROSOFT_AZURE_APPSERVICE_JARENTRYPOINT_PREFIX__//'`

# Strip off the suffix
APPSERVICE_MANGLED_MAIN_CLASS_NAME=`echo "${APPSERVICE_MANGLED_MAIN_CLASS_NAME}" | sed 's/__COM_MICROSOFT_AZURE_APPSERVICE_JARENTRYPOINT_SUFFIX__.*//'`

# Note the extracted main class name
APPSERVICE_MAIN_CLASS_NAME="${APPSERVICE_MANGLED_MAIN_CLASS_NAME}"
echo "Extracted jar entry point. Class name is: '$APPSERVICE_MAIN_CLASS_NAME'"

# Set user.dir to the directory that contains the main app JAR
APP_JAR_FOLDER=$(dirname $APP_JAR_PATH)
export JAVA_OPTS="$JAVA_OPTS -Duser.dir=$APP_JAR_FOLDER"

# Configure JVM encoding. If -Dfile.encoding is not defined default to UTF-8
# if -Dfile.encoding is defined in app setting leave as is.
if [[ -z "$(echo "$JAVA_OPTS" | grep -i Dfile.encoding)" ]]
then
    export JAVA_OPTS="-Dfile.encoding=UTF-8 $JAVA_OPTS"
    echo "Defaulting to UTF-8"
fi

if [ -n "$APPSERVICE_MAIN_CLASS_NAME" ] # $APPSERVICE_MAIN_CLASS_NAME is a non-empty string
then
    # Configure AzMon utilities if WEBSITE_SKIP_AZMON_CONFIG not defined or false
    if [[ -z "$WEBSITE_SKIP_AZMON_CONFIG" || "$WEBSITE_SKIP_AZMON_CONFIG" = "false" || "$WEBSITE_SKIP_AZMON_CONFIG" = "0" ]] 
    then
        export JAVA_OPTS="-Djava.util.logging.config.file=/usr/local/appservice/logging.properties $JAVA_OPTS"
        export APP_JAR_PATH="$APP_JAR_PATH:/usr/local/appservice/lib/azure.appservice.jar"
    fi
    CMD="java -cp $APP_JAR_PATH:$APPSERVICE_EXTERNAL_JARS $JAVA_OPTS $APPSERVICE_MAIN_CLASS_NAME"
else
    echo "Failed to query jar entry point. Falling back to legacy command-line"
    CMD="java $JAVA_OPTS -jar $APP_JAR_PATH"
fi

echo Running command: "$CMD"

# Start the process in the background, so that the installed signal handlers can continue to receive signals as expected.
# If the process is started in the foreground, we will miss receiving the signals.
$CMD &
GLOBAL_PID_MAIN=$!

echo Launched child process with pid: $GLOBAL_PID_MAIN

# BEGIN: Wait for the child process to exit

# NOTE: This script has to be sourced for it to work (Refer script's documentation for more details)
source /bin/wait_for_main_process.sh

echo Exiting entry script!

# END: Wait for the child process to exit
