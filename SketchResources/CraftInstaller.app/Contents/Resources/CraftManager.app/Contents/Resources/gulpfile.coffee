gulp = require 'gulp'
gutil = require 'gulp-util'
path = require 'path'
fs = require 'fs'
del = require 'del'
template = require 'gulp-template'
runSequence = require 'run-sequence'
{execSync} = require 'child_process'
plist = require 'plist'
peditor = require 'gulp-plist'
request = require 'sync-request'
{parseString} = require 'xml2js'

production = process.argv.indexOf("--prod") >- 1;

derivedDataPath = "DerivedData"
buildLocation = "#{derivedDataPath}/Build/Products/Release"
buildPath = path.join(__dirname, buildLocation)
appName = 'CraftManager'
installerAppName = 'CraftInstaller'
installerBasePath = path.join(__dirname, '../craft-installer-mac')
frontendBasePath = path.join(__dirname, '../craft-manager-frontend')
installerPath = path.join(installerBasePath, installerAppName)
installerBuildPath = path.join(installerBasePath, buildLocation)

config =
    buildPath: buildPath
    appName: appName
    distPath: path.join(__dirname, 'dist')
    appCastPath: path.join(__dirname, 'appcast.xml')
    appCastNoDsaPath: path.join(__dirname, 'appcastNoDsa.xml')
    appCastBuildPath: path.join(buildPath, 'appcast.xml')
    appProjectPath: path.join(__dirname, appName)
    infoPlistPath: path.join(__dirname, "#{appName}/Info.plist")
    zipPath: path.join(buildPath, "#{appName}.zip")
    appPath: path.join(buildPath, "#{appName}.app")
    installerBasePath: installerBasePath
    installerPath: installerPath
    installerAppPath: path.join(installerPath, "#{appName}.app")
    installerZipPath: path.join(installerBuildPath, "#{installerAppName}.zip")
    installerBuildPath: installerBuildPath
    pemPath: path.join(__dirname, 'dsa_priv.pem')
    signUpdate: path.join(__dirname, 'sparkle-bin/sign_update')
    #developerSignature: "Developer ID Application: InVisionApp Inc."
    #developerSignature: "Developer ID Application: Tomas Hanacek"
    developerSignature: "F0BBDF27893B7F532BF16731A2D5FD1773F2B97F"

config.craftUrlProd="https://craft-assets.invisionapp.com/CraftManager/production/"
config.craftUrlBeta="https://craft-assets.invisionapp.com/CraftManager/beta/"

amazonBucketProdOld="www-assets.invisionapp.com/labs/craft/manager/"
amazonBucketBetaOld="www-assets.invisionapp.com/labs/craft/manager/manager-beta/"

amazonBucketProd="craft-assets.invisionapp.com/CraftManager/production/"
amazonBucketBeta="craft-assets.invisionapp.com/CraftManager/beta/"

if production
    config.production = true
    config.amazonBucket = amazonBucketProd
    config.amazonBucketOld = amazonBucketProdOld
    config.craftUrl = config.craftUrlProd
else
    config.production = false
    config.amazonBucket = amazonBucketBeta
    config.amazonBucketOld = amazonBucketBetaOld
    config.craftUrl = config.craftUrlBeta

console.log("Production: '#{config.production}'")
console.log("Amazon bucket: '#{config.amazonBucket}'")
console.log("Craft URL: '#{config.craftUrl}'")

gulp.task 'clean', ->
    managerDerivedDataPath = path.join(__dirname, derivedDataPath)
    installerDerivedDataPath = path.join(installerBasePath, derivedDataPath)
    del([config.distPath, config.installerBuildPath, config.installerAppPath, config.zipPath, managerDerivedDataPath, installerDerivedDataPath], force: true)

gulp.task 'build-manager', ->
    execSync("xcodebuild -workspace CraftManager.xcworkspace -scheme CraftManager -derivedDataPath #{derivedDataPath} CODE_SIGN_IDENTITY='#{config.developerSignature}' -configuration Release build", { stdio: [0, 1, 2] })
    process.chdir(config.buildPath)
    execSync("zip -r -y #{config.appName}.zip #{config.appName}.app")

gulp.task 'generate-appcast', ->
    data = plist.parse(fs.readFileSync(config.infoPlistPath, 'utf8'))
    dsaSignature = execSync("#{config.signUpdate} #{config.zipPath} #{config.pemPath}").toString().replace(/\r?\n|\r/g, "")

    gulp.src(config.appCastPath)
        .pipe(template({
            buildVersion: data.CFBundleVersion
            shortVersionString: data.CFBundleShortVersionString
            pubDate: new Date().toUTCString()
            zipLength: fs.statSync(config.zipPath).size
            craftUrl: config.craftUrl
            dsaSignature: dsaSignature
        }))
        .pipe(gulp.dest(config.buildPath))

gulp.task 'generate-appcast-no-dsa', (callback) ->
    runSequence(
        'generate-appcast-no-dsa-1',
        'generate-appcast-no-dsa-2',
        callback)

gulp.task 'generate-appcast-no-dsa-1', ->
    data = plist.parse(fs.readFileSync(config.infoPlistPath, 'utf8'))

    gulp.src(config.appCastNoDsaPath)
        .pipe(template({
            buildVersion: data.CFBundleVersion
            shortVersionString: data.CFBundleShortVersionString
            pubDate: new Date().toUTCString()
            zipLength: fs.statSync(config.zipPath).size
            craftUrl: config.craftUrl
        }))
        .pipe(gulp.dest(config.buildPath))

gulp.task 'generate-appcast-no-dsa-2', ->
    execSync("mv #{config.buildPath}/appcastNoDsa.xml #{config.buildPath}/appcast.xml")

gulp.task 'copy-to-installer', ->
    execSync("cp -R '#{config.appPath}' '#{config.installerAppPath}'")

gulp.task 'build-installer', ->
    process.chdir(config.installerBasePath)
    execSync("xcodebuild -workspace #{installerAppName}.xcworkspace -scheme #{installerAppName} -derivedDataPath #{derivedDataPath} CODE_SIGN_IDENTITY='#{config.developerSignature}' -configuration Release build", { stdio: [0, 1, 2] })
    process.chdir(config.installerBuildPath)
    execSync("zip -r -y #{installerAppName}.zip #{installerAppName}.app")

gulp.task 'set-appcast-url', ->
    gulp.src(config.infoPlistPath)
        .pipe(peditor({
            SUFeedURL: "#{config.craftUrl}appcast.xml"
            SUFeedURLProd: "#{config.craftUrlProd}appcast.xml"
            SUFeedURLBeta: "#{config.craftUrlBeta}appcast.xml"
            SUPublicDSAKeyFile: 'dsa_pub.pem'
        }))
        .pipe(gulp.dest(config.appProjectPath))

gulp.task 'upload-to-s3', ->
    if process.argv.indexOf("--noupload") >- 1
        console.log "No upload"
        return
    execSync("aws s3 cp #{config.distPath} s3://#{config.amazonBucket} --recursive --acl public-read", { stdio: [0, 1, 2] })
    #copy to old destination.
    execSync("aws s3 cp s3://#{config.amazonBucket}appcast.xml s3://#{config.amazonBucketOld}appcast.xml --acl public-read", { stdio: [0, 1, 2] })
    execSync("aws s3 cp s3://#{config.amazonBucket}CraftManager.zip s3://#{config.amazonBucketOld}CraftManager.zip --acl public-read", { stdio: [0, 1, 2] })
    execSync("aws s3 cp s3://#{config.amazonBucket}CraftInstaller.zip s3://#{config.amazonBucketOld}CraftInstaller.zip --acl public-read", { stdio: [0, 1, 2] })

gulp.task 'copy-to-dist', ->
    gulp.src([config.zipPath, config.appCastBuildPath, config.installerZipPath])
        .pipe(gulp.dest(config.distPath))

gulp.task 'default', (callback) ->
    runSequence(
        'clean',
        'set-appcast-url',
        'build-manager',
        'generate-appcast',
        'copy-to-installer',
        'build-installer',
        'copy-to-dist',
        callback)

#this task increments the build and version number from the live app cast
gulp.task 'increment-version', ->
    if process.argv.indexOf("--noincrement") >- 1
        console.log "No increment"
        return
    uri = "https://s3.amazonaws.com/#{config.amazonBucket}appcast.xml"
    console.log("Getting Version from #{uri}")
    getVersion uri, (err, buildNumber, versionNumber) ->
        if err
            throw err
        console.log("Current version #{versionNumber} (#{buildNumber})")
        buildNumber = (parseInt(buildNumber) + 1).toString()
        versionNumber = incrementVersionNumber(versionNumber)
        console.log("Next version #{versionNumber} (#{buildNumber})")
        config.versionNumber = versionNumber
        config.buildNumber = buildNumber
        gulp.src(config.infoPlistPath)
            .pipe(peditor({
                CFBundleVersion: buildNumber
                CFBundleShortVersionString: versionNumber
            }))
            .pipe(gulp.dest(config.appProjectPath))

gulp.task 'backup-s3-version', ->
    if process.argv.indexOf("--nobackup") >- 1
        console.log "No backup"
        return

    uri = "https://s3.amazonaws.com/#{config.amazonBucket}appcast.xml"
    getVersion uri, (err, buildNumber, versionNumber) ->
        if err
            throw err
        fromPath="s3://#{config.amazonBucket}"
        destPath="s3://#{config.amazonBucket}versions/#{versionNumber}-#{buildNumber}/"
        console.log("From Path: #{fromPath}")
        console.log("Dest Path: #{destPath}")

        execSync("aws s3 cp #{fromPath}appcast.xml #{destPath}appcast.xml", { stdio: [0, 1, 2] })
        execSync("aws s3 cp #{fromPath}CraftInstaller.zip #{destPath}CraftInstaller.zip", { stdio: [0, 1, 2] })
        execSync("aws s3 cp #{fromPath}CraftManager.zip #{destPath}CraftManager.zip", { stdio: [0, 1, 2] })

gulp.task 'tag-branch', ->
    if process.argv.indexOf("--notag") >- 1
        console.log "No tag"
        return
    process.chdir(config.appProjectPath)

    data = plist.parse(fs.readFileSync(config.infoPlistPath, 'utf8'))
    buildNumber = data.CFBundleVersion
    versionNumber = data.CFBundleShortVersionString

    if config.production
        env = "release"
    else
        env = "beta"
    tag = "#{env}-#{versionNumber}-#{buildNumber}"
    console.log "Tag: #{tag}"

    execSync("git add -A")
    execSync("git commit -m 'Changes for #{env} #{versionNumber}-#{buildNumber}'")
    branch = execSync("git branch | sed -n -e 's/^\\* \\(.*\\)/\\1/p'")
    console.log("Branch: #{branch}")
    execSync("git push origin #{branch}")
    execSync("git tag #{tag}")
    execSync("git push origin #{tag}")

gulp.task 'create-release-branch', ->
    uri = "https://s3.amazonaws.com/#{config.amazonBucket}appcast.xml"
    getVersion uri, (err, buildNumber, versionNumber) ->
        if err
            throw err
        buildNumber = (parseInt(buildNumber) + 1).toString()
        versionNumber = incrementVersionNumber(versionNumber)
        branch = "branch-#{versionNumber}-#{buildNumber}"
        console.log("Branch: #{branch}")
        execSync("git checkout master")
        execSync("git pull origin master")
        execSync("git checkout -b #{branch}")

gulp.task 'build-frontend', ->
    execSync("gulp --gulpfile '#{frontendBasePath}/gulpfile.coffee'")

gulp.task 'cloudfront-invalidation', ->
    if config.production
        env = "production"
    else
        env = "beta"
    execSync("aws configure set preview.cloudfront true")
    execSync("aws cloudfront create-invalidation --distribution-id E9MTE3E9ESDLE --paths /CraftManager/#{env}/appcast.xml /CraftManager/#{env}/CraftInstaller.zip /CraftManager/#{env}/CraftManager.zip", { stdio: [0, 1, 2] })

gulp.task 'pull-request', ->
    if config.production
        env = "production"
    else
        env = "beta"

    data = plist.parse(fs.readFileSync(config.infoPlistPath, 'utf8'))
    buildVersion = data.CFBundleVersion
    shortVersionString = data.CFBundleShortVersionString

    msg = "#{env} release for #{shortVersionString}-#{buildVersion}"

    pullRequest = execSync("hub pull-request -b master -m '#{msg}'")
    if process.argv.indexOf("--set-pr-env") != -1
        execSync("envman add --key IN_PULL_REQUEST --value '#{pullRequest}'")

gulp.task 'deploy', (callback) ->
    runSequence(
        'backup-s3-version',
        'increment-version',
        'default',
        'upload-to-s3',
        'backup-s3-version',
        'tag-branch',
            callback)

#this method returns the current live version and build number for the sparcle appcast
getVersion = (uri, callback) ->
    res = request('GET', uri)
    parseString res.getBody(), (err, result) ->
        attr = result["rss"]["channel"][0]["item"][0]["enclosure"][0]["$"];
        buildNumber = attr["sparkle:version"]
        versionNumber = attr["sparkle:shortVersionString"]
        callback(err, buildNumber, versionNumber)


incrementVersionNumber = (versionNumber) ->
    versionParts = versionNumber.split('.');
    count = versionParts.length
    if count < 3
        return versionNumben
    versionNumber = versionParts[count-3] + '.' + versionParts[count-2] + '.' + (parseInt(versionParts[count-1]) + 1).toString()
    if config.production == false
        versionNumber = "beta." + versionNumber
    return versionNumber
