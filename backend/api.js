'use strict';

const { v4: uuidV4 } = require('uuid');
const jwt = require('jsonwebtoken');

module.exports = class ServerApi {
    constructor(host = null, authorization = null, apiKeySecret = null, jwtSecret = null) {
        this._host = host;
        this._authorization = authorization;
        this._api_key_secret = apiKeySecret;
        this._jwt_secret = jwtSecret;
    }

    isAuthorized() {
        if (this._authorization != this._api_key_secret) return false;
        return true;
    }

    getMeetingURL() {
        return this.getProtocol() + this._host + '/?room=' + uuidV4();
    }

    getJoinURL(data) {
        return this.getProtocol() + this._host + '/join?room=' + data.room + '&name=' + data.name;
    }

    // LIMITED mode: create a JWT-based time-limited session link
    createSession(duration_minutes, session_name, start_time_ms) {
        const room = uuidV4();
        const start_time = start_time_ms != null && Number.isFinite(start_time_ms) ? start_time_ms : Date.now();
        const duration_ms = (duration_minutes != null ? duration_minutes : 180) * 60 * 1000;
        const end_time = start_time + duration_ms;

        const payload = {
            room,
            session_name: session_name || null,
            start_time,
            end_time,
        };

        // expiresIn is relative to now, so account for a future start_time
        const expiresInSec = Math.ceil((end_time - Date.now()) / 1000) + 120;
        const token = jwt.sign(payload, this._jwt_secret, { expiresIn: expiresInSec });
        return this.getProtocol() + this._host + '/?token=' + token;
    }

    getProtocol() {
        return 'http' + (this._host.includes('localhost') ? '' : 's') + '://';
    }
};
