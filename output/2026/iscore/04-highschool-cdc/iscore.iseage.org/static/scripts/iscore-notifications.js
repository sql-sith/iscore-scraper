function base64ToArrayBuffer(base64String) {
    const padding = '='.repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding)
        .replace(/\-/g, '+')
        .replace(/_/g, '/');

    const rawData = window.atob(base64);
    const outputArray = new Uint8Array(rawData.length);

    for (let i = 0; i < rawData.length; ++i) {
        outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
}

let pushButton = document.getElementById('btn-push-notifications');
let serverKey = document.getElementById('applicationServerKey');
let subId = null;

if (serverKey && serverKey.value) {
    serverKey = serverKey.value;
} else {
    serverKey = "";
}

const opts = {
    userVisibleOnly: true,
    applicationServerKey: base64ToArrayBuffer(serverKey)
};


if (Notification.permission == "denied") {
    unsubscribe(true);
}

/**
 * TODO: Work out how the front-end for this is going to work
 */
if ('serviceWorker' in navigator) {

    console.log('Service Worker is supported');
    navigator.serviceWorker.register('/sw.js').then(reg => {

        let no_push = getCookie('no_push');

        if (serverKey) {
            console.log(':^)', reg);

            if (no_push) {
                console.log("[PUSH] no_push enabled, not attempting to subscribe automatically");
            } else {
                subscribe(null);
            }

            if (pushButton) {
                console.log("We have the push button");

                if (no_push) {
                    console.log('[PUSH] Show subscription button');
                    pushButton.classList.add('btn-info');
                    pushButton.innerHTML = "Subscribe";
                    pushButton.classList.remove('hidden');
                    pushButton.addEventListener('click', subscribe);
                } else {
                    reg.pushManager.permissionState(opts).then(state => {
                        if (state === 'granted') {
                            pushButton.classList.add('btn-info');
                            pushButton.innerHTML = "Unsubscribe";
                            pushButton.classList.remove('hidden');

                            pushButton.addEventListener('click', unsubscribe);
                        } else if (state !== 'granted') {
                            pushButton.parentNode.removeChild(pushButon);
                        }
                    }).catch(err => {
                        console.error("There was an error checking push status", err);
                    })
                }
            } else {
                console.log("We aren't on the user profile page");
            }
        } else {
            console.log("No application server key, not registering for push notifications");
        }
    });
}

function subscribe(evt) {
    navigator.serviceWorker.getRegistration().then(reg => {
        reg.pushManager.subscribe(opts).then(sub => {
            console.log('endpoint:', sub.endpoint);
            // Deal with subscription;

            sub = sub.toJSON();
            const data = {
                'endpoint': sub.endpoint,
                'auth': sub.keys.auth,
                'p256dh': sub.keys.p256dh,
            };

            $.ajax({
                type: "POST",
                url: "/api/v1/push",
                data: data,
                success: (data) => {
                    subId = data.id;
                    console.log("Registered push notifications");
                    pushButton.innerHTML = "Unsubscribe";
                    window.location.reload();
                },
                error: (err) => {
                    if (err.status === 400) {
                        console.log("Already registered! :)");
                    } else {
                        console.error("Error registering for push", err);
                    }
                }
            });
        }).catch(err => {
            console.log(':^(', err);
        });
    });
}

function unsubscribe(evt) {
    if (evt !== true) {
        pushButton.classList.add('disable');
    }

    console.log("Unsubscribing");

    navigator.serviceWorker.getRegistration().then(reg => {
        reg.pushManager.getSubscription().then(sub => {
            if (!sub) {
                console.log("We were'nt subscribed");
                return;
            }

            let subData = sub.toJSON();
            const data = {
                'endpoint': subData.endpoint,
            };

            console.info("Removing subscription info");
            console.debug("Endpoint:", encodeURIComponent(data.endpoint));
            $.ajax({
                type: "DELETE",
                url: `/api/v1/push/0?endpoint=${encodeURIComponent(data.endpoint)}`,
                data: data,
                success: data => {
                    console.log("Unregistered push notifications");
                },
                error: err => {
                    console.error("Error unsubscribing:", err);
                }
            });

            sub.unsubscribe().then(successful => {
                console.log("We've unsubscribed");
                pushButton.innerHTML = "Subscribe";
                pushButton.removeEventListener('click', unsubscribe);
                pushButton.classList.remove('disable');
                window.location.reload();
            }).catch(err => {
                console.error("Couldn't unsubscribe:", err);
                window.location.reload();
            });

        });
    });
}
