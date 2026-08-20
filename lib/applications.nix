#
# The cluster catalogue: what nixshare's cluster-side applications ARE.
#
# WHAT BELONGS HERE. This repository's subject is doing something TO bytes -- handing a file to
# somebody, serving a tree as objects, making the same tree exist on two machines -- and it is
# indifferent to what the bytes MEAN. That indifference is the whole test. A document store that
# indexes what it holds, a photo library that knows a photo is a photo, a wiki: those read their
# content, and they have owners of their own. What is catalogued here would behave identically if
# every byte in it were noise.
#
# The host side of this repository says the same thing in a different vocabulary: a share is a
# filesystem somewhere else, mounted here. These are the same act performed by a server rather than
# a mount -- which is why they live in one repository and not in the apps grab-bag.
#
# WHAT IS KNOWLEDGE AND WHAT IS A VALUE. Everything in this file is true of the software wherever
# anyone runs it: the port it listens on, the directory it writes, whether it may be pointed at a
# directory that does not exist yet, which environment variables it reads a credential out of, how
# patient a probe has to be. Nothing here names an address, a node, a hostname, a namespace or a
# secret's contents -- those are one deployment's facts and they arrive from the consumer. The
# split is enforced rather than trusted: `state` here is the path INSIDE the container and only a
# declaration can say what backs it; `credentials` here is the variable the process reads and only
# a declaration can say which Secret holds it.
#
# THE FIELDS THAT ARE NOT IN A GENERIC CATALOGUE, and why this domain grew them:
#
#   mayStartEmpty  Which of this software's directories it may be pointed at before they exist.
#                  This is the domain's characteristic fact. An S3 gateway that comes up on an
#                  empty backend does not fail -- it serves, and reports every bucket as gone. A
#                  sync client that comes up on an empty identity directory does not fail either;
#                  it mints a new device and stops being the peer its partners know. Both are
#                  silent, and both are decided by a single `hostPath.type` the consumer would
#                  otherwise have to know to set. It is knowledge, so it is not the consumer's.
#
#   writeProbe     Which directories must be PROVEN WRITABLE before the process starts. Present
#                  but not writable is the failure a mount check does not catch: the pod starts,
#                  answers its health endpoint, serves reads, and fails every write.
#
#   mayIdle        Whether sleeping to zero replicas is SAFE for this software -- not whether it
#                  is wanted, which is a deployment's call. Two of the three here must not sleep,
#                  and neither reason is about size.
#
#   trailingArgs   The words the command line must END with. A flag can go anywhere; a POSITIONAL
#                  argument cannot, and a catalogue that kept one `args` list would append a
#                  deployment's own flags AFTER the positional pair and hand the process a command
#                  line it rejects. The ordering is the software's, so both halves are held here
#                  and a declaration's arguments go BETWEEN them.
#
#   privileges     What the process needs from the KERNEL, and therefore what may be taken away
#                  from it. `null` means NOBODY HAS ESTABLISHED IT -- which is not "it needs
#                  everything" and not "it needs nothing", and renders no securityContext at all,
#                  so an application whose live container carries none keeps carrying none.
#                  Establishing it is a real change to a running pod, not a documentation edit.
{}:
{
  applications = {
    pingvin = {
      image = "stonith404/pingvin-share";

      # The Next.js frontend. It proxies to a backend on another port INSIDE the container, which
      # is why nothing else is declared here and why the readiness path below matters.
      ports.http = { number = 3000; protocol = "TCP"; };
      primaryPort = "http";

      # ONE DIRECTORY, holding an opaque SQLite database and the uploads tree beside it. That
      # single fact decides the workload's whole shape: a database file is a SINGLE-WRITER
      # resource, so two pods sharing it is two writers on one file, so the deployment cannot roll
      # -- the old pod must be gone before the new one starts. A consumer never states that;
      # declaring state is what states it.
      state.data = "/opt/app/backend/data";

      # NEITHER directory may be created empty. The database is the app's entire configuration as
      # well as its content, and an empty one is a fresh installation with no shares in it. The
      # directory also has to be owned by the account the container runs as, which nothing inside
      # the cluster does for you -- a directory the kubelet creates arrives owned by root.
      mayStartEmpty = [ ];

      # NOTHING. ALL configuration -- the public URL, SMTP, an OAuth client -- lives inside the
      # SQLite database, so there is no Secret to name: preserving the data directory preserves the
      # configuration. Stated as an empty set rather than left out, because the assertion that
      # every credential the software reads is supplied reads this attribute.
      credentials = { };

      writeProbe = [ ];

      # NOTHING FROM THE KERNEL, and this one IS established: it is a Node HTTP server that binds
      # one high port, writes one directory and shells out to nothing. It needs no Linux capability
      # and runs no setuid helper, so both halves of the container's privilege can be closed --
      # which is a statement about the software, true wherever it runs, and not a policy somebody
      # applied to one cluster.
      #
      # WHAT IS DELIBERATELY NOT CLAIMED HERE is a read-only root filesystem. It very probably
      # holds, and "very probably" is the wrong standard for a field whose failure mode is a
      # process that starts and then cannot write.
      privileges = { needsCapabilities = false; escalates = false; };

      env = { };
      args = [ ];
      trailingArgs = [ ];

      # `/api/configs` proxies through to the backend, so Ready means the FULL app serves rather
      # than that the frontend socket is open. That distinction is load-bearing under a wake front:
      # the interceptor forwards the held request the moment the pod goes Ready, and a cheaper
      # probe hands it to a half-booted app. 30 x 5s is 150 seconds of cold-start tolerance.
      readiness = {
        path = "/api/configs";
        periodSeconds = 5;
        failureThreshold = 30;
      };

      # A BARE TCP CHECK, on purpose, and the one place where the two probes must not agree. It
      # must never restart a pod that is merely slow to answer a proxied backend call -- readiness
      # owns "is it serving", this owns "is it alive", and conflating them is how a slow start
      # becomes a restart loop that reads as the application's fault.
      liveness = {
        periodSeconds = 20;
        failureThreshold = 6;
      };

      mayIdle = true;

      note = ''
        A file-sharing service: upload a file or a folder, hand somebody a link, optionally with an
        expiry and a password. The thing an email attachment limit makes you go looking for.

        IT IS OPENED BY A PERSON, DELIBERATELY, and that is what makes it the one application here
        that may sleep. Nothing in it fires on a timer and nothing watches a directory; between two
        uploads it holds a file and does no work, so at zero replicas there is no work that fails
        to happen. That is the actual test for whether idling is safe, rather than whether the
        workload is small.

        THE DATABASE IS THE CONSTRAINT, not the size. It cannot roll, cannot have a second replica
        and cannot share its directory -- because SQLite is single-writer, and none of those follow
        from how much traffic it takes.

        NOTHING IS PINNED HERE. The version and the digest are a deployment's, and for this
        application the choice is unusually sharp: a new image is a `Recreate` on a live SQLite
        file, so upgrading it is downtime rather than a blip. That is a reason to pin it, not a
        reason to leave it floating.
      '';
    };

    versitygw = {
      image = "versity/versitygw";

      ports.s3 = { number = 7070; protocol = "TCP"; };
      primaryPort = "s3";

      # TWO DIRECTORIES, and they are not the same kind of thing. `/data` is the POSIX tree that IS
      # the object store -- buckets are directories, objects are files, and the gateway invents
      # none of it. `/iam` is the gateway's own record of who may touch which bucket.
      state.data = "/data";
      state.iam = "/iam";

      # THE ASYMMETRY IS THE POINT. The backend must ALREADY EXIST: a gateway pointed at a
      # directory that is not there, and given permission to create it, comes up perfectly healthy
      # and reports every bucket as gone -- which reads to every client as data loss rather than as
      # a misconfiguration. The IAM directory is the opposite: the gateway populates it itself on
      # first use, so demanding it exist first would refuse a first run for no reason.
      mayStartEmpty = [ "iam" ];

      # THE ROOT S3 CREDENTIAL, named by the variables the process reads and never carried. These
      # two are the administrative keys for every bucket the gateway fronts; which Secret holds
      # them, and under which keys, is a deployment's business.
      credentials.root = [ "ROOT_ACCESS_KEY" "ROOT_SECRET_KEY" ];

      # PROVE THE BACKEND IS WRITABLE BEFORE STARTING. The failure this catches is the silent one:
      # the mount is present but not writable -- a read-only dataset, a wrong owner -- and the
      # gateway would then start, answer its health endpoint, serve every read and fail every PUT.
      # Touching and removing one file first turns that into a pod that never becomes ready.
      writeProbe = [ "data" ];

      # NOT ESTABLISHED, and left that way on purpose. Nobody has checked what the gateway wants
      # from the kernel, and a catalogue that guessed "nothing" would be hardening every running
      # instance of it on a guess -- silently, since a dropped capability the process actually
      # needed surfaces as a syscall failing somewhere inside an S3 request rather than as a pod
      # that refuses to start.
      privileges = null;

      env = { };

      # The gateway takes its bind spec and its backend root on the command line, so the port and
      # both mount paths appear here a second time. That repetition is the software's, not this
      # file's -- and the checks assert the two copies agree rather than trusting them to.
      #
      # The administration API binds LOOPBACK ONLY. That is not a deployment preference: the admin
      # plane creates users and re-owns buckets, so a gateway whose public Service could reach it
      # would publish the ability to grant access to itself. Anything that needs it shares the
      # pod's network namespace.
      args = [
        "--port"
        ":7070"
        "--admin-port"
        "127.0.0.1:7071"
        "--health"
        "/health"
        "--iam-dir"
        "/iam"
        "--access-log"
        "/dev/stdout"
      ];

      # THE BACKEND SELECTOR AND ITS ROOT, and they are POSITIONAL: the gateway reads them off the
      # end of its argv, so every flag -- the catalogue's above and whatever a deployment adds --
      # has to come before them. Keeping them in `args` would mean a declaration that adds one flag
      # gets a command line ending `posix /data --its-flag`, which is not the same command and is
      # not a command this gateway accepts. The order is the software's; this is where it is held.
      trailingArgs = [ "posix" "/data" ];

      readiness = {
        path = "/health";
        initialDelaySeconds = 3;
        periodSeconds = 10;
      };

      # DELIBERATELY SLACK -- five failures at thirty seconds is two and a half minutes. The
      # backend is a POSIX tree on whatever disks somebody gave it, and a slow `stat` is not a dead
      # gateway. A tight liveness probe here restarts the process that is holding the slow disk.
      liveness = {
        path = "/health";
        initialDelaySeconds = 10;
        periodSeconds = 30;
        timeoutSeconds = 5;
        failureThreshold = 5;
      };

      # IT MUST NOT SLEEP, and the reason is not traffic. Its clients are programs, not people: an
      # SDK opens a multipart upload and expects the endpoint to be there for every part of it,
      # and a wake front holds ONE request. Nothing here measures how long a cold start takes --
      # what is recorded is that an S3 endpoint's callers do not tolerate one.
      mayIdle = false;

      note = ''
        An S3 gateway over a POSIX filesystem: it speaks the S3 API and stores what it is given as
        ordinary files and directories on a tree somebody else curates. Nothing is repacked, so
        every object remains readable by the tools that were reading that tree before.

        THAT IS WHY IT IS A SHARE AND NOT A DATABASE. It adds a protocol to bytes that already
        exist rather than taking custody of them, which is the same act as exporting a directory
        over NFS -- performed by a server that speaks HTTP.

        IT IS A SINGLE WRITER ON THAT TREE. Two gateways over one POSIX root is two processes
        deciding what a bucket contains, so the deployment cannot roll; declaring durable state is
        what states that, and this application declares two.

        WHAT IS NOT HERE. Resource requests and limits are a deployment's, because they are a
        statement about one cluster's appetite rather than about this software. A tenant identity
        below the root credential is likewise a deployment's: which users exist and what they may
        reach is the shape of one installation, and the mechanism for creating them is the
        administration API the arguments above deliberately keep on loopback.
      '';
    };

    syncthing = {
      image = "lscr.io/linuxserver/syncthing";

      # FOUR PORTS, THREE PROTOCOLS, and only one of them is a web interface. The peer protocol
      # takes both TCP and UDP on the same number -- the UDP half is QUIC -- and discovery is UDP
      # on its own number. A catalogue that recorded only the web port would describe a workload
      # that cannot do the one thing it is for.
      ports.webui = { number = 8384; protocol = "TCP"; };
      ports.sync-tcp = { number = 22000; protocol = "TCP"; };
      ports.sync-udp = { number = 22000; protocol = "UDP"; };
      ports.discovery = { number = 21027; protocol = "UDP"; };
      primaryPort = "webui";

      # TWO DIRECTORIES, and the first one is an IDENTITY rather than data. `/config` holds the
      # device key, its certificate and the index of everything this device believes it has; the
      # synced tree itself is `/syncthing`, and the folder paths recorded in the configuration must
      # agree with wherever that tree is mounted.
      state.config = "/config";
      state.data = "/syncthing";

      # NEITHER may be created empty, and this is the sharpest instance of the field in the
      # catalogue. An empty `/config` is not a broken start -- Syncthing generates a fresh device
      # key, comes up perfectly healthy, and is a DIFFERENT PEER, so every partner that trusted the
      # old device now refuses it. An empty `/syncthing` is worse still: to a device that still
      # holds its index, a tree whose files are all missing is a tree whose files were all deleted,
      # and it will say so to everybody it syncs with.
      mayStartEmpty = [ ];

      # THE REST API KEY. Syncthing's API accepts this key INSTEAD of a GUI session and skips both
      # the login form and the CSRF check, so it is a full administrative credential in its own
      # right -- which is why it is required here rather than optional. Supplying it from the
      # environment also keeps the running configuration file from being the authority for it.
      #
      # IT IS NOT THE WHOLE DOOR, and this file will not pretend otherwise: the GUI's own username
      # and password live inside the configuration on `/config`, which is application state and not
      # anything a rendered manifest can write. Closing that half is a deployment's job.
      credentials.gui = [ "STGUIAPIKEY" ];

      writeProbe = [ ];

      # NOT ESTABLISHED, and this is the entry where guessing "nothing" would be plainly wrong.
      # The image starts as root, chowns its own configuration and drops to the account it was
      # told to run as -- which is privilege escalation performed on purpose, by the only part of
      # the image that can. Closing it here would produce a container that cannot become the user
      # whose files it is supposed to be reading.
      privileges = null;

      env = { };
      args = [ ];
      trailingArgs = [ ];

      # THE ONE BUDGET HERE THAT IS NOT READ OFF A RUNNING DEPLOYMENT. Every other probe in this
      # catalogue comes from an installation that is live; this application is still declared
      # through a Helm chart on an older shape that states no probe at all, so these numbers come
      # from the recipe that packaged it. They are recorded as its numbers, not measured as ours.
      readiness = {
        path = "/";
        initialDelaySeconds = 10;
        periodSeconds = 10;
        failureThreshold = 3;
      };

      liveness = {
        path = "/";
        initialDelaySeconds = 30;
        periodSeconds = 30;
        failureThreshold = 3;
      };

      # IT MUST NOT SLEEP, and here the reason is definitional rather than practical. Continuous
      # synchronisation at zero replicas is not synchronisation, and nothing would bring it back:
      # its peers speak a protocol of their own, so an HTTP wake front never sees them knocking.
      # Idling it would leave a device that is reachable exactly when nobody needs it.
      mayIdle = false;

      note = ''
        Continuous file synchronisation between devices, peer to peer. No server owns the data; a
        set of devices agree to hold the same folder and reconcile it directly, which is the other
        way a file comes to exist in two places -- the first being a share this repository mounts.

        THE IDENTITY IS THE ASSET, not the data. The data is by definition somewhere else as well;
        the device key is not, and losing it does not lose files but does lose every relationship
        that referred to them. Everything in this entry that looks over-careful about `/config` is
        that fact.

        IT IS A SINGLE WRITER ON ITS OWN CONFIGURATION. Two processes holding one index and one
        lock file corrupt both, so it cannot roll; the durable state says so.

        ITS WEB INTERFACE IS AN ADMINISTRATIVE INTERFACE. It edits which folders exist and which
        devices are trusted -- there is no read-only view of it -- so wherever it can be reached
        from is a decision about who may re-point the synchronisation, not about who may look.
      '';
    };
  };
}
