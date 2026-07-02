# slurm-gpu-guard

I work on an HPC cluster where we allow power users to directly SSH to compute nodes and execute on bare metal. We do have slurm, but purely for GPU allocation - we do not enforce resource allocations via cgroups. Consequently, within a slurm job, we rely on most frameworks respecting the `CUDA_VISIBLE_DEVICES` env var that gets set (note that in our setup, the GPU index set by the env var is host global and not job local, as again we do not enforce isolation with cgroups).

The difficulty is, we occasionally have users who forget to use slurm to reserve the GPUs they want to use. In such cases, **this guard script is designed to detect and kill processes which are sitting on unallocated GPUs**. A major caveat, if a process is using a specific GPU, we do not enforce that the process was started by the job which allocated that GPU. The primary reason for this design is because a slurm job can start docker containers which would not reliably trace back to the either the job or even the user (we don't use rootless). The consequence is that a user could potentially hijack another user's allocated GPU, but we're a small enough team that this isn't too much of an issue that accidental instances of this can't be resolved on slack.

The specific way this works:
1. get a mapping of GPU index (used by slurm) to GPU UUID
2. get a list of processes using GPU and which GPUs (by UUID) they're using
3. get a list of GPUs (by index) allocated by slurm
4. kill any processes using onallocated GPUs

## usage

Dry run:
```bash
sudo DRY_RUN=1 bash gpu-guard.sh
```

Armed:
```bash
sudo bash gpu-guard.sh
```

**Disclaimer**: script written by claude opus 4.8
