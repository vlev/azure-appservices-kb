#!/usr/bin/env bash

### Usage instructions ###
## NOTE: This script has to be sourced for it to work.
## This WILL NOT work: ./appservice_helper.sh 
## This WILL work: source ./appservice_helper.sh

# Default values of well-known global variables used by this script
export GLOBAL_PID_MAIN=0
export GLOBAL_EXIT_AFTER_CUSTOM_STARTUP=0



#######################################################################
#
#     Start up 
#
#######################################################################

#
# This function installs the specified signal handlers
# Param1: The signal that was trapped
# Return value: None. However, this function will exit the calling process.
#
_terminate_main_process()
{
    echo Received signal $1
    
    if [ $GLOBAL_PID_MAIN -ne 0 ]
    then
        echo Sending SIGTERM to main process. Child Process ID: $GLOBAL_PID_MAIN
        kill -SIGTERM $GLOBAL_PID_MAIN
        wait $GLOBAL_PID_MAIN
    else
        echo Skipped sending SIGTERM to main process. Child Process ID: $GLOBAL_PID_MAIN
    fi
    
    echo Done processing signal $1. Exiting now!
    
    # Sending a SIGTERM to main process will exit the main process.
    # But we want to exit explicitly even if main process is yet to be started.
    exit 
}

#
# Install the SIGINT and SIGTERM signal handlers
#
install_signal_handlers()
{
    trap '_terminate_main_process SIGINT' SIGINT
    trap '_terminate_main_process SIGTERM' SIGTERM
}

#
# Perform custom container startup
# Parameters: Optional. Command-line to use for performing custom start up.
# Return value: None. If the GLOBAL_EXIT_AFTER_CUSTOM_STARTUP environment vairable is set to 1
# then this function will exit the calling process after the custom startup is complete.
#
perform_custom_startup()
{
    DEFAULT_STARTUP_FILE=/home/site/scripts/startup.sh
    DEFAULT_STARTUP_FILE_DEPRECATED=/home/startup.sh
    STARTUP_FILE=
    STARTUP_COMMAND=

    # The web app can be configured to run a custom startup command or a custom startup script
    # This custom command / script will be available to us as a param ($1, $2, ...)
    #
    # IF $1 is a non-empty string AND an existing file, we treat $1 as a startup file (and ignore $2, $3, ...)
    # IF $1 is a non-empty string BUT NOT an existing file, we treat $@ (equivalent of $1, $2, ... combined) as a startup command
    # IF $1 is an empty string AND one of the default startup files exist, we use it as the startup file
    # ELSE, we skip running the startup script / command
    #
    if [ -n "$1" ] # $1 is a non-empty string
    then
        if [ -f "$1" ] # $1 file exists
        then
            STARTUP_FILE=$1
        else
            STARTUP_COMMAND=$@
        fi
    elif [ -f $DEFAULT_STARTUP_FILE ] # Default startup file path exists
    then
        STARTUP_FILE=$DEFAULT_STARTUP_FILE
    elif [ -f $DEFAULT_STARTUP_FILE_DEPRECATED ] # Deprecated default startup file path exists
    then
        STARTUP_FILE=$DEFAULT_STARTUP_FILE_DEPRECATED
    fi

    echo STARTUP_FILE=$STARTUP_FILE
    echo STARTUP_COMMAND=$STARTUP_COMMAND

    # If $STARTUP_FILE is a non-empty string, we need to run the startup file
    if [ -n "$STARTUP_FILE" ]
    then

        # Copy startup file to a temporary location and fix the EOL characters in the temp file (to avoid changing the original copy)
        TMP_STARTUP_FILE=/tmp/startup.sh
        echo Copying $STARTUP_FILE to $TMP_STARTUP_FILE and fixing EOL characters in $TMP_STARTUP_FILE
        cp $STARTUP_FILE $TMP_STARTUP_FILE
        dos2unix $TMP_STARTUP_FILE
        
        echo Running STARTUP_FILE: $TMP_STARTUP_FILE
        source $TMP_STARTUP_FILE
        # Capture the exit code before doing anything else
        EXIT_CODE=$?
        
        echo Finished running startup file \'$TMP_STARTUP_FILE\'. Exit code: \'$EXIT_CODE\'.
        if [[ "$GLOBAL_EXIT_AFTER_CUSTOM_STARTUP" = "1" ]]
        then
            echo Custom startup complete. Now, exiting with exit code \'$EXIT_CODE\'
            exit $EXIT_CODE
        fi
    else
        echo No STARTUP_FILE available.
    fi

    if [ -n "$STARTUP_COMMAND" ]
    then
        echo Running STARTUP_COMMAND: "$STARTUP_COMMAND"
        $STARTUP_COMMAND
        # Capture the exit code before doing anything else
        EXIT_CODE=$?
        
        echo Finished running startup file \'$STARTUP_COMMAND\'. Exit code: \'$EXIT_CODE\'.
        if [[ "$GLOBAL_EXIT_AFTER_CUSTOM_STARTUP" = "1" ]]
        then
            echo Custom startup complete. Now, exiting with exit code \'$EXIT_CODE\'
            exit $EXIT_CODE
        fi
    else
        echo No STARTUP_COMMAND defined.
    fi
}

#
# Print container info
#
# Prints useful debugging info about the container that is starting up
#
print_container_info()
{
    echo "Container info: WEBSITE_INSTANCE_ID = $WEBSITE_INSTANCE_ID ; WEBSITE_SITE_NAME = $WEBSITE_SITE_NAME"
}


#######################################################################
#
#     Java config
#
#######################################################################

#
# Configure Java heap
#
# Detects environment variables and decides whether to apply a platform-suggested max-heap flag to the JVM
#
configure_java_heap()
{
    if [[ "$WEBSITE_DISABLE_JAVA_HEAP_CONFIGURATION" = "1" ||  "$WEBSITE_DISABLE_JAVA_HEAP_CONFIGURATION" = "true" ]]
    then
        WEBSITE_JAVA_MAX_HEAP_MB=
        echo "Disabling Java heap configuration"
    fi

    if [ -n "$WEBSITE_JAVA_MAX_HEAP_MB" ] # WEBSITE_JAVA_MAX_HEAP_MB is configured by the platform
    then
        # Check if the flags -Xms or -Xmx have been provided in JAVA_OPTS
        if [[ "$JAVA_OPTS" == *"-Xms"* || "$JAVA_OPTS" == *"-Xmx"* ]]
        then
            echo "Using Java heap configuration provided in JAVA_OPTS instead of the platform suggested configuration"
        else
            echo "Configuring max heap = $WEBSITE_JAVA_MAX_HEAP_MB MB"
            export JAVA_TOOL_OPTIONS="-Xmx${WEBSITE_JAVA_MAX_HEAP_MB}M $JAVA_TOOL_OPTIONS"
        fi
    else
        echo "Using default max heap configuration"
    fi
}

#
# Configure Java keystore
#
# Add public and private certificates to the Java Key Store
#

configure_java_keystore()
{
# check for jks password
if [ -z $WEBSITE_JAVA_KEYSTORE_PASSWORD ]
then
    WEBSITE_JAVA_KEYSTORE_PASSWORD="changeit"
else
    keytool -storepasswd -keystore $JRE_HOME/lib/security/cacerts -storepass "changeit" -new $WEBSITE_JAVA_KEYSTORE_PASSWORD
fi
export WEBSITE_JAVA_KEYSTORE_PASSWORD #export variable to be used 

# Add client certificates to keystore. 
if [ -z $SKIP_JAVA_KEYSTORE_LOAD ]
then
    echo "Add public certificates to keystore if exists..."
    addToTrustStore="false"
    for file in /var/ssl/certs/*
    do
        test -f "$file" || continue
        thumbprint=$(basename $file| cut -d. -f1)
        echo "Adding thumbprint ${thumbprint}"    
        keytool -importcert -alias ${thumbprint} -file $file -keystore $JRE_HOME/lib/security/cacerts -storepass $WEBSITE_JAVA_KEYSTORE_PASSWORD -noprompt
        addToTrustStore="true"
    done

    # Set default path for trustStore
    if [ "$addToTrustStore" == "true" ] # wildfly doesn't like empty keystore to be set
    then
        echo "Set default trustStore..."
        export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$JRE_HOME/lib/security/cacerts $JAVA_TOOL_OPTIONS"
        export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStorePassword=$WEBSITE_JAVA_KEYSTORE_PASSWORD $JAVA_TOOL_OPTIONS"    
    fi

    echo "Add private certificates to keystore if exists..."
    addToKeyStore="false"
    for file in /var/ssl/private/*
    do
        test -f "$file" || continue
        thumbprint=$(basename $file| cut -d. -f1)
        echo "Adding thumbprint ${thumbprint}"
        
        # Java8 doesn't support import of private cert with empty password
        openssl pkcs12 -in $file -out /tmp/$thumbprint.pem -passin pass: -passout pass:temppassword
        openssl pkcs12 -export -in /tmp/$thumbprint.pem -out /tmp/$thumbprint.p12 -passin  pass:temppassword -passout pass:$WEBSITE_JAVA_KEYSTORE_PASSWORD

        # import private certificate to KeyStore
        keytool -v -importkeystore -srckeystore /tmp/$thumbprint.p12 -srcstoretype PKCS12 -srcstorepass $WEBSITE_JAVA_KEYSTORE_PASSWORD -destkeystore $JRE_HOME/lib/security/client.jks -deststorepass $WEBSITE_JAVA_KEYSTORE_PASSWORD -srcalias 1 -destalias ${thumbprint} -noprompt -deststoretype pkcs12 -destkeypass $WEBSITE_JAVA_KEYSTORE_PASSWORD    

        # cleanup
        rm -rf /tmp/$thumbprint.pem
        rm -rf /tmp/$thumbprint.p12

        addToKeyStore="true"
    done

    # Set default path for keyStore
    if [ "$addToKeyStore" == "true" ] # JBoss doesn't like empty keystore to be set
    then
        echo "Set default keyStore..."
        export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.keyStore=$JRE_HOME/lib/security/client.jks $JAVA_TOOL_OPTIONS"
        export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.keyStorePassword=$WEBSITE_JAVA_KEYSTORE_PASSWORD $JAVA_TOOL_OPTIONS"
        export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.keyStoreType=PKCS12 $JAVA_TOOL_OPTIONS"
    fi
fi

}

#
# Configure Java error handlers
#
# Add flags to configure crash behavior and where to save log files and memory dumps
#

configure_java_error_handlers()
{
if [ -z $WEBSITE_SKIP_DUMP_ON_OUT_OF_MEMORY ]
then
    export JAVA_OPTS="$JAVA_OPTS -XX:ErrorFile=/home/LogFiles/java_error_${WEBSITE_SITE_NAME}_${COMPUTERNAME}_%p.log"
    export JAVA_OPTS="$JAVA_OPTS -XX:+CrashOnOutOfMemoryError"
    export JAVA_OPTS="$JAVA_OPTS -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/home/LogFiles/java_memdump_${WEBSITE_SITE_NAME}_${COMPUTERNAME}.log"
fi
}

#
# Configure Tomcat error report valve
#
# Defaults to App Service error page and hidden stack trace/server information
#
configure_tomcat_error_report()
{
    # App Service custom error page
    if [[ -z "$WEBSITE_TOMCAT_APPSERVICE_ERROR_PAGE" || "$WEBSITE_TOMCAT_APPSERVICE_ERROR_PAGE" = "true" || "$WEBSITE_TOMCAT_APPSERVICE_ERROR_PAGE" = "1" ]] 
    then
        echo "App Service Error Page enabled"
        export JAVA_OPTS="$JAVA_OPTS -DappService.valves.appServiceErrorPage=true"
    else
        echo "App Service Error Page disabled, defaulting to Tomcat Error Report Valve Page"
        export JAVA_OPTS="$JAVA_OPTS -DappService.valves.appServiceErrorPage=false"
    fi

    # Default Tomcat ErrorReportValve Parameters
    if [[ -z "$WEBSITE_TOMCAT_ERROR_DETAILS" || "$WEBSITE_TOMCAT_ERROR_DETAILS" = "false" || "$WEBSITE_TOMCAT_ERROR_DETAILS" = "0" ]] 
    then
        echo "Catalina Error Report Valve hidden"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.valves.showReport=false"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.valves.showServerInfo=false"
    else
        echo "Catalina Error Report Valve customized to visible"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.valves.showReport=true"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.valves.showServerInfo=true"
    fi
}

#
# TOMCAT
# Set HTTP Connector information
#
# Custom App Setting for customer to choose max connections
#
configure_catalina_maxthreads_maxconnections()
{
    #
    # Max Threads
    #
    if [[ "$JAVA_OPTS" == *"catalina.maxThreads"* ]]
    then
        echo "Catalina max threads is set in JAVA_OPTS"
    elif [ -z "$WEBSITE_CATALINA_MAXTHREADS" ]
    then
        WEBSITE_CATALINA_MAXTHREADS="200"   

        echo "Configuring default catalina max threads of $WEBSITE_CATALINA_MAXTHREADS, change with WEBSITE_CATALINA_MAXTHREADS"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.maxThreads=$WEBSITE_CATALINA_MAXTHREADS"     
    else
        echo "Configuring custom catalina max threads of $WEBSITE_CATALINA_MAXTHREADS"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.maxThreads=$WEBSITE_CATALINA_MAXTHREADS"   
    fi

    #
    # Max Connections
    #
    if [[ "$JAVA_OPTS" == *"catalina.maxConnections"* ]]
    then
        echo "Catalina max connections is set in JAVA_OPTS"
    elif [ -z "$WEBSITE_CATALINA_MAXCONNECTIONS" ]
    then
        WEBSITE_CATALINA_MAXCONNECTIONS="10000"   

        echo "Configuring default catalina max connections of $WEBSITE_CATALINA_MAXCONNECTIONS, change with WEBSITE_CATALINA_MAXCONNECTIONS"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.maxConnections=$WEBSITE_CATALINA_MAXCONNECTIONS"     
    else
        echo "Configuring custom catalina max connections of $WEBSITE_CATALINA_MAXCONNECTIONS"
        export JAVA_OPTS="$JAVA_OPTS -Dcatalina.maxConnections=$WEBSITE_CATALINA_MAXCONNECTIONS"   
    fi 
}

#
# Convert XML to XSLT
#
# Extensible Stylesheet Language (XSL) is used to transform and render XML documents
# Transform xsl transform against server.xml and context.xml
#
transform_conf_XMLs()
{
    # server.xml
    serverFilePath="/usr/local/tomcat/conf/server.xml"
    xslFilePath="/usr/local/tomcat/conf/server.xml.xsl"    

    if [ -f $xslFilePath ]
    then
        echo "Using $xslFilePath to modify $serverFilePath"
        xsltproc --output $serverFilePath $xslFilePath $serverFilePath
    fi

    # context.xml
    contextFilePath="/usr/local/tomcat/conf/context.xml"
    xslFilePath="/usr/local/tomcat/conf/context.xml.xsl"    

    if [ -f $xslFilePath ]
    then
        echo "Using $xslFilePath to modify $contextFilePath"
        xsltproc --output $contextFilePath $xslFilePath $contextFilePath
    fi
}


#######################################################################
#
#     Utilities
#
#######################################################################

#
# Retry
#
# Generic function that given a command, executes it and expects a success exit code.
# Otherwise it sleeps for an increasingly larger time upto a maximum wait time.
# 
# By default it will wait up to 1 + 2 + 4 + ... + 2048 = 4095 seconds (~68 minutes)
#
# Can be used to retry copying from a network share into the container's own disk,
# eg. `retry cp -r -f /home/site/wwwroot/app.jar /local/site/wwwroot`
#
# This function will be used mostly to cover the scenario where there is a storage failover
# which makes all the sites in one worker to fail over another worker and suddenly all sites
# will try to perform the cold start activation at the same time which hammers the file server.
#

retry() {
    SLEEP_TIME="1"
    MAX_SLEEP="2048" # Do not sleep more than 2048 seconds

    RETRIES="0"
    # MAX_RETRIES defaults to -1 to retry indefinitely.
    # This works because we always INCREMENT the number of retries and check for equality.
    MAX_RETRIES="-1"

    # Arguments parsing
    while [[ $# > 0 ]]
    do
    key="$1"

    case $key in
        -s|--sleep)
        SLEEP_TIME="$2"
        shift # past argument
        ;;
        -m|--max)
        MAX_SLEEP="$2"
        shift # past argument
        ;;
        -r|--retries)
        MAX_RETRIES="$2"
        shift # past argument
        ;;
        *)
        break # unknown option
        ;;
    esac
    shift # past argument or value
    done

    # The command is all remaining arguments
    COMMAND=`printf "%q " "$@"`

    if [ "$(echo $COMMAND)" == "''" ]
    then
        echo "No command given"
        return 2
    fi


    # Print and run the command
    echo $COMMAND
    eval $COMMAND

    # If the return code of running the command is not zero AND we have not reached the maximum retries
    while [ $? -ne 0 -a $RETRIES -ne $MAX_RETRIES ]
    do
        # Report, sleep
        echo "Command failed - retrying in $SLEEP_TIME seconds..."
        sleep $SLEEP_TIME

        # If the current sleep time is less than the maximum, then double it
        if [ $SLEEP_TIME -lt $MAX_SLEEP ]
        then
            SLEEP_TIME=$(($SLEEP_TIME * 2)) # Exponential backoff
        fi

        # Update the number of retries and run the command again
        RETRIES=$(($RETRIES + 1))
        eval $COMMAND
    done

    if [ $? -ne 0 -a $RETRIES -eq $MAX_RETRIES ]
    then
        echo "Maximum number of retries ($MAX_RETRIES) reached, aborting."
        return 1
    fi
}


#######################################################################
#
#     Copying app files 
#
#######################################################################

#
# Sets designated jar file to find first
#
designated_jar_file()
{
    # check for custom jar file
    if [ -z $WEBSITE_JAVA_JAR_FILE_NAME ]
    then
        WEBSITE_JAVA_JAR_FILE_NAME="app.jar"
    else
        echo "Designated file name to look for first WEBSITE_JAVA_JAR_FILE_NAME=$WEBSITE_JAVA_JAR_FILE_NAME"
    fi
}

#
# Sets designated war file to find first
#
designated_war_file()
{
    # check for custom war file
    if [ -z $WEBSITE_JAVA_WAR_FILE_NAME ]
    then
        WEBSITE_JAVA_WAR_FILE_NAME="app.war"
    else
        echo "Designated file name to look for first WEBSITE_JAVA_WAR_FILE_NAME=$WEBSITE_JAVA_WAR_FILE_NAME"
    fi
}

#
# Find File to deploy for Tomcat app
#
tomcat_copy_app_files()
{
    designated_war_file # set designated file

    # default siteroot location
    SITEROOT=/usr/local/tomcat/webapps
    DEPLOYMENT_PATH=/home/site/wwwroot
  
    # 0. WEBSITE_JAVA_WAR_FILE_NAME app setting copy WEBSITE_JAVA_WAR_FILE_NAME.war as ROOT.war
    #    OR app.war if WEBSITE_JAVA_WAR_FILE_NAME not specified 
    if [[ -n "$WEBSITE_JAVA_WAR_FILE_NAME" && -n `find /home/site/wwwroot -maxdepth 1 -type f -name $WEBSITE_JAVA_WAR_FILE_NAME` ]]
    then 
        FIRST_WAR=($(find -L /home/site/wwwroot/ -maxdepth 1 -type f -name "$WEBSITE_JAVA_WAR_FILE_NAME" | head -1))
        echo "Using $FIRST_WAR with SITEROOT=$SITEROOT"
        # /usr/local/tomcat/webapps/ROOT.war is default Tomcat application path
        retry cp $FIRST_WAR $SITEROOT/ROOT.war;

        # Enable WAR unpacking as we are sure only one app is present at this location
        # So we don't have to worry about locking issues. On the other hand, this will provide some performance improvements.
        TOMCAT_UNPACK_WARS=true
        TOMCAT_APP="$WEBSITE_JAVA_WAR_FILE_NAME as ROOT"

    # 1. Non-Root War
    elif [[ -n `find /home/site/wwwroot -maxdepth 1 -type f -name "*.war"` ]]
    then
        echo "Found WAR files in /home/site/wwwroot, deploying all WARs" 

        for WARFILE in /home/site/wwwroot/*.war;
        do
            retry cp "$WARFILE" $SITEROOT;
            echo "Copying $WARFILE from /home/site/wwwroot/ to SITEROOT=$SITEROOT"
        done

        TOMCAT_UNPACK_WARS=true
        TOMCAT_APP="Non-Root"

    # 2. Legacy deployment
    elif [[ -d /home/site/wwwroot/webapps && -n `ls -A /home/site/wwwroot/webapps` ]]
    then
        # Legacy Tomcat deployment creates /home/site/wwwroot/webapps
        DEPLOYMENT_PATH=/home/site/wwwroot/webapps
        retry cp -r $DEPLOYMENT_PATH/* $SITEROOT;

        # Only unpack if war file present
        if [[ -n `find /home/site/wwwroot -type f -name *.war` ]]
        then
            TOMCAT_UNPACK_WARS=true
        fi

        TOMCAT_APP="Legacy"
    # 3. Stand alone JSPs
    elif [[ -n `find /home/site/wwwroot -type f -name *.jsp` ]]
    then
        # By default, if JSPs are found copy all files to SITEROOT
        echo "JSPs found, copying home/site/wwwroot to $SITEROOT"
        mkdir -p $SITEROOT/ROOT
        retry cp -r $DEPLOYMENT_PATH/* $SITEROOT/ROOT;

        TOMCAT_APP="Jsp"
        JAVA_COPY_ALL=false

    # 4. Default Parking Page
    else
        SITEROOT=/usr/local/appservice/parkingpage
        echo "Using parking page app with SITEROOT=$SITEROOT"

        # Enable WAR unpacking as we are sure only one app is present at this location
        # So we don't have to worry about locking issues. On the other hand, this will provide some performance improvements.
        TOMCAT_APP="Parking Page"
        TOMCAT_UNPACK_WARS=true
    fi

    echo "$TOMCAT_APP deployment"
}


#
# Find File to deploy for JavaSE App
#
java_copy_app_files()
{
    designated_jar_file
    designated_war_file

    # default siteroot location
    SITEROOT=/local/site/wwwroot

    # 0a. Check if WEBSITE_JAVA_JAR_FILE_NAME is an absolute path first
    if [ -f $WEBSITE_JAVA_JAR_FILE_NAME ]
    then 
        APP_JAR_PATH=$WEBSITE_JAVA_JAR_FILE_NAME

    elif [ -f "/home/site/wwwroot/$WEBSITE_JAVA_JAR_FILE_NAME" ]
    then
        APP_JAR_PATH="/home/site/wwwroot/$WEBSITE_JAVA_JAR_FILE_NAME"

    # 0b. Search WEBSITE_JAVA_JAR_FILE_NAME app setting copy WEBSITE_JAVA_JAR_FILE_NAME.jar as ROOT.jar
    #    OR app.jar if WEBSITE_JAVA_JAR_FILE_NAME not specified 
    elif [[ -n `find /home/site/wwwroot -maxdepth 1 -type f -name $WEBSITE_JAVA_JAR_FILE_NAME` ]]
    then 
        APP_JAR_PATH=($(find -L /home/site/wwwroot/ -maxdepth 1 -type f -name "$WEBSITE_JAVA_JAR_FILE_NAME" | head -1))

    # 1. Any Jar
    elif [[ -z $WEBJOBS_ROOT_PATH && ! -d "/home/site/wwwroot/app_data/jobs" && -n `find /home/site/wwwroot -type f -name *.jar` ]]
    then
        echo "Found other jar files in /home/site/wwwroot, choosing the first one alphabetically" 
        APP_JAR_PATH=($(find -L /home/site/wwwroot/ -type f -name "*.jar" | head -1))

    # 2a. Check if WEBSITE_JAVA_WAR_FILE_NAME is an absolute path first
    elif [ -f $WEBSITE_JAVA_WAR_FILE_NAME ]
    then 
        APP_JAR_PATH=$WEBSITE_JAVA_WAR_FILE_NAME

    elif [ -f "/home/site/wwwroot/$WEBSITE_JAVA_WAR_FILE_NAME" ]
    then
        APP_JAR_PATH="/home/site/wwwroot/$WEBSITE_JAVA_WAR_FILE_NAME"

    # 2b. WEBSITE_JAVA_WAR_FILE_NAME app setting copy WEBSITE_JAVA_WAR_FILE_NAME.war as ROOT.war
    #    OR app.war if WEBSITE_JAVA_WAR_FILE_NAME not specified 
    elif [[ -n `find /home/site/wwwroot -maxdepth 1 -type f -name $WEBSITE_JAVA_WAR_FILE_NAME` ]]
    then 
        APP_JAR_PATH=($(find -L /home/site/wwwroot/ -maxdepth 1 -type f -name "$WEBSITE_JAVA_WAR_FILE_NAME" | head -1))

    # 3. Any Executable War
    elif [[ -n `find /home/site/wwwroot -maxdepth 1 -type f -name *.war` ]]
    then
        echo "Found other war files in /home/site/wwwroot, choosing the first one alphabetically" 
        APP_JAR_PATH=($(find -L /home/site/wwwroot/ -maxdepth 1 -type f -name "*.war" | head -1))

    # 4. Default Parking Page
    else
        APP_JAR_PATH=/usr/local/appservice/parkingpage.jar
        echo "Could not find an excecutable jar in /home/site/wwwroot/ or any subdirectory. Using default parking page at $APP_JAR_PATH"
    fi
}

#
# update_arguments
#
# Define options for a launcher script
#
# Takes at least 3 arguments:
# - a string with options to be passed to the JBoss launcher script
# - a string with a default value
# - all remaining arguments (flags) will be used to determine if the options will stay the same or not
#
# If the options string contains any of the flags, the user has provided said flag and the options stay the same.
# Otherwise, the default value is appended to the options.
#
# Examples:
#
# update_arguments '--input foo.txt --verbose' '-quiet' '-v' '--verbose'
# returns '--input foo.txt --verbose' (flag already found)
#
# update_arguments '--input foo.txt --format pdf' '-quiet' '-v' '--verbose'
# returns '--input foo.txt --format pdf -quiet' (no flag found, default is appended)

function update_arguments()
{
  # Capture and then drop the two first arguments to the function
  OPTIONS=$1
  DEFAULT=$2
  shift
  shift

  # Review the remaining arguments (flags) for matches
  for FLAG in "$@"; do
    # Note: we add a space to the left to prevent matching substrings (eg. '-f' matching '--out-file')
    if [[ " ${OPTIONS}" == *" ${FLAG}"* ]]; then
      # $FLAG found in $OPTIONS, leave untouched
      echo "$OPTIONS"
      return 0
    fi
  done

  # At this point we know $OPTIONS doesn't contain any of the flags, so we append the default value to the options
  echo "$OPTIONS $DEFAULT"
  return 0
}

#
# create_jboss_ds_module
#
# Create JBoss DataSource modules for different datasources
# based on the parameters given:
# - key: the name of the environment variable to look up for a JDBC URL
# - shortname: short name of the database name, i.e. "postgres"
# - driver: name of the JDBC driver class to use, i.e. "org.postgresql.Driver"
# - xadriver: name of the JDBC driver class for the XA Datasource, i.e. "org.postgresql.xa.PGXADataSource"
# - jcaprefix: prefix to be used to locate the JCA Adapter, i.e. "PostgreSQL"
#

function create_jboss_ds_module() {
  key="$1"
  shortname="$2"
  driver="$3"
  xadriver="$4"
  jcaprefix="$5"

  # List of all the JARs for the given driver
  jars=`ls -1d /usr/local/appservice/jdbc/${shortname}/*.jar 2> /dev/null | tr '\n' ':'`

  # Use the following as the JNDI name
  datasourceName="${key}_DS"

  # Create the CLI file
  echo "Running JBoss CLI to create datasource $datasourceName..."
  JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS_AGENTLESS $JBOSS_HOME/bin/jboss-cli.sh --connect --no-color-output $JBOSS_CLI_OPTS <<EOF
if (outcome != success) of /subsystem=datasources/jdbc-driver=${shortname}:read-resource
  module add --name=${shortname} --resources=${jars} --dependencies=[javax.api,javax.transaction.api]

  /subsystem=datasources/jdbc-driver=${shortname}:add(driver-name=${shortname},driver-module-name=${shortname},driver-class-name=${driver},driver-xa-datasource-class-name=${xadriver})
end-if

data-source add --name=${datasourceName} --driver-name=${shortname} --jndi-name=java:jboss/env/jdbc/$datasourceName --connection-url=\${env.${key}} --use-ccm=true --max-pool-size=5 --blocking-timeout-wait-millis=5000 --enabled=true --driver-class=${driver} --exception-sorter-class-name=org.jboss.jca.adapters.jdbc.extensions.${jcaprefix}ExceptionSorter --jta=true --use-java-context=true --valid-connection-checker-class-name=org.jboss.jca.adapters.jdbc.extensions.${jcaprefix}ValidConnectionChecker

EOF
}

function create_jboss_database_connection_ds() {

    if [[ -z $WEBSITE_SKIP_AUTOCONFIGURE_DATABASE || "$WEBSITE_SKIP_AUTOCONFIGURE_DATABASE" = "false" || "$WEBSITE_SKIP_AUTOCONFIGURE_DATABASE" = "0" ]]; then

        # Environment variables containing the value 'jdbc'
        for key in $(env | grep jdbc | awk -F= '{ print $1 }' | sed 's/^APPSETTING_//g')
        do
            echo "Inspecting $key ..."
            # PostgreSQL
            if [[ "${!key}" == *"jdbc:postgresql://"* ]]; then
                create_jboss_ds_module "$key" "postgresql" "org.postgresql.Driver" "org.postgresql.xa.PGXADataSource" "postgres.PostgreSQL"
            fi

            # MySQL
            if [[ "${!key}" == *"jdbc:mysql://"* ]]; then
                create_jboss_ds_module "$key" "mysql" "com.mysql.cj.jdbc.Driver" "com.mysql.cj.jdbc.MysqlXADataSource" "mysql.MySQL"
            fi

            # MariaDB - Note that the JCA adapters are the same as for MySQL, hence "mysql.MySQL" in the last parameter
            if [[ "${!key}" == *"jdbc:mariadb://"* ]]; then
                create_jboss_ds_module "$key" "mariadb" "org.mariadb.jdbc.Driver" "org.mariadb.jdbc.MariaDbDataSource" "mysql.MySQL"
            fi

            # Oracle
            if [[ "${!key}" == *"jdbc:oracle:"* ]]; then
                create_jboss_ds_module "$key" "oracle" "oracle.jdbc.driver.OracleDriver" "oracle.jdbc.xa.client.OracleXADataSource" "oracle.Oracle"
            fi

            # SQL Server
            if [[ "${!key}" == *"jdbc:sqlserver://"* ]]; then
                create_jboss_ds_module "$key" "sqlserver" "com.microsoft.sqlserver.jdbc.SQLServerDriver" "com.microsoft.sqlserver.jdbc.SQLServerXADataSource" "mssql.MSSQL"
            fi

        done
    fi
}

# Tomcat configure Database Connections
create_tomcat_database_connection_ds() {
    if [[ -z $WEBSITE_SKIP_AUTOCONFIGURE_DATABASE || "$WEBSITE_SKIP_AUTOCONFIGURE_DATABASE" = "false" || "$WEBSITE_SKIP_AUTOCONFIGURE_DATABASE" = "0" ]]; then
        for connectionENV in $(env | grep -E "jdbc:.*://")
        do
            # Skip over connection strings without password
            if [[ ! $connectionENV =~ "password=" ]]; then
                continue
            fi

            # Separate Connection String Name with Value
            envKey=${connectionENV%%=*}
            val=${connectionENV#*=}

            # Context- Name, Auth, Type, URL
            resourceName="jdbc/${envKey}_DS"
            resourceAuth='Container'
            resourceType='javax.sql.DataSource' 
            JAVA_OPTS="$JAVA_OPTS -D$envKey.url='$val'"

            # Extract arguments on connection url
            argumentString=$(cut -d "?" -f2- <<< $val )

            # Context- Driver class for resource
            # Copy jars to CATALINA_BASE/lib
            if [[ "${!envKey}" == *"jdbc:postgresql://"* ]]; then
                resourceDriverClassName='org.postgresql.Driver'
                separationToken="&"
                mkdir -p /usr/local/tomcat/appservice/lib
                retry cp -r "/usr/local/tomcat/appservice/jdbc/postgresql/"* "/usr/local/tomcat/appservice/lib"
            elif [[ "${!envKey}" == *"jdbc:mysql://"* ]]; then
                resourceDriverClassName='com.mysql.cj.jdbc.Driver'
                separationToken="&"
                mkdir -p /usr/local/tomcat/appservice/lib
                retry cp -r "/usr/local/tomcat/appservice/jdbc/mysql/"* "/usr/local/tomcat/appservice/lib"
            elif [[ "${!envKey}" == *"jdbc:sqlserver://"* ]]; then
                resourceDriverClassName='com.microsoft.sqlserver.jdbc.SQLServerDriver'
                separationToken=";"
                mkdir -p /usr/local/tomcat/appservice/lib
                retry cp -r "/usr/local/tomcat/appservice/jdbc/sqlserver/"* "/usr/local/tomcat/appservice/lib"
            fi
            
            # Context- User and Password
            IFS="$separationToken" read -ra VALUES <<< $argumentString;
            for parameter in "${VALUES[@]}"; do
                if [[ $parameter =~ "&" ]]; then
                    parameter=$(cut -d "&" -f1 <<< $parameter)
                fi

                if [[ $parameter =~ "user" ]]; then
                    resourceUser=$(cut -d "=" -f2 <<< $parameter)
                    JAVA_OPTS="$JAVA_OPTS -D$envKey.user=$resourceUser"
                elif [[ $parameter =~ "password" ]]; then
                    resourcePassword=$(cut -d "=" -f2 <<< $parameter)
                    JAVA_OPTS="$JAVA_OPTS -D$envKey.password=$resourcePassword"
                fi
            done

            # Configure JNDI Resource in context.xml
            contextFilePath="/usr/local/tomcat/conf/context.xml"
            xslFilePath="/usr/local/tomcat/conf/resource.xml.xsl"

            echo "Configuring $envKey Resource with JNDI name $resourceName and $resourceDriverClassName"
            xsltproc --stringparam resourceName "$resourceName" \
                    --stringparam resourceAuth "$resourceAuth" \
                    --stringparam resourceDriverClassName "$resourceDriverClassName"\
                    --stringparam resourceURL "\${$envKey.url}" \
                    --stringparam resourceType "$resourceType" \
                    --stringparam resourceUsername "\${$envKey.user}" \
                    --stringparam resourceUser "\${$envKey.user}" \
                    --stringparam resourcePassword "\${$envKey.password}" \
                    --output $contextFilePath $xslFilePath $contextFilePath
         
        done
    fi
}