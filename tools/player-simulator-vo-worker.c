/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Included after vo_thread's declaration in the locked mpv video/out/vo.c.
 * Simulator only: its EGL driver retains one teleport connection per thread,
 * even after EGL teardown and thread exit. Reuse one executor; each VO still
 * runs the complete upstream init/render/uninit lifecycle. No media is cached.
 */
static pthread_mutex_t pm_sim_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pm_sim_wakeup = PTHREAD_COND_INITIALIZER;
static pthread_t pm_sim_thread;
static struct vo *pm_sim_job;
static bool pm_sim_started, pm_sim_reserved, pm_sim_quit;

static void *pm_sim_executor(void *unused)
{
    pthread_mutex_lock(&pm_sim_lock);
    for (;;) {
        while (!pm_sim_job && !pm_sim_quit)
            pthread_cond_wait(&pm_sim_wakeup, &pm_sim_lock);
        if (!pm_sim_job && pm_sim_quit)
            break;
        struct vo *vo = pm_sim_job;
        pm_sim_job = NULL;
        pthread_mutex_unlock(&pm_sim_lock);
        vo_thread(vo);
        mp_thread_set_name("pm-sim-vo-idle");
        pthread_mutex_lock(&pm_sim_lock);
        vo->in->pm_sim_done = true;
        vo = NULL;
        pthread_cond_broadcast(&pm_sim_wakeup);
    }
    pthread_mutex_unlock(&pm_sim_lock);
    return NULL;
}

static int pm_sim_start_vo(struct vo *vo)
{
    pthread_mutex_lock(&pm_sim_lock);
    // An unrelated simultaneous VO must never wait for the first to stop.
    if (pm_sim_reserved || pm_sim_quit) {
        pthread_mutex_unlock(&pm_sim_lock);
        return mp_thread_create(&vo->in->thread, vo_thread, vo);
    }
    if (!pm_sim_started) {
        int error = pthread_create(&pm_sim_thread, NULL, pm_sim_executor, NULL);
        if (error) {
            pthread_mutex_unlock(&pm_sim_lock);
            return error;
        }
        pm_sim_started = true;
    }
    pm_sim_reserved = true;
    vo->in->pm_sim_reused = true;
    vo->in->thread = pm_sim_thread;
    pm_sim_job = vo;
    pthread_cond_broadcast(&pm_sim_wakeup);
    pthread_mutex_unlock(&pm_sim_lock);
    return 0;
}

static void pm_sim_join_vo(struct vo *vo)
{
    if (!vo->in->pm_sim_reused) {
        mp_thread_join(vo->in->thread);
        return;
    }
    pthread_mutex_lock(&pm_sim_lock);
    while (!vo->in->pm_sim_done)
        pthread_cond_wait(&pm_sim_wakeup, &pm_sim_lock);
    // The executor has cleared every reference before the VO can be freed.
    pm_sim_reserved = false;
    pthread_mutex_unlock(&pm_sim_lock);
}

__attribute__((destructor)) static void pm_sim_shutdown(void)
{
    pthread_mutex_lock(&pm_sim_lock);
    pm_sim_quit = true;
    pthread_cond_broadcast(&pm_sim_wakeup);
    bool started = pm_sim_started;
    pthread_mutex_unlock(&pm_sim_lock);
    if (started)
        pthread_join(pm_sim_thread, NULL);
}
