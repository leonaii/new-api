import { API } from '../helpers';

const ModelListAuthService = {
  // 验证密码
  async verifyPassword(password) {
    const response = await API.post('/api/model-list/verify-password', { password });
    return response.data;
  },

  // 检查验证状态
  async checkStatus() {
    const response = await API.get('/api/model-list/password-status');
    return response.data;
  },

  // 获取模型列表数据
  async getModelListData() {
    const response = await API.get('/api/model-list/data');
    return response.data;
  },
};

export default ModelListAuthService;
